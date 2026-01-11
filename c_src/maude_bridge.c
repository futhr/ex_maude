/*
 * ExMaude C-Node Bridge
 *
 * A C-Node process that manages a Maude subprocess and communicates
 * with the Erlang/Elixir VM using Erlang distribution protocol.
 *
 * This provides:
 * - Binary Erlang term protocol (no text parsing overhead)
 * - Full process isolation (C-Node crash doesn't affect BEAM)
 * - Lower latency than Port + PTY wrapper
 *
 * Usage:
 *   ./maude_bridge <node_name> <cookie> <maude_path> <erlang_node>
 *
 * Protocol:
 *   {execute, Command :: binary()} -> {:ok, Output :: binary()} | {:error, Reason}
 *   ping -> pong
 *   stop -> ok
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <sys/wait.h>
#include <sys/select.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#include <ei.h>

/* Forward declarations */
static void handle_message(int fd, erlang_msg *emsg, ei_x_buff *buf);
static int read_until_prompt(char *output, int max_len, int timeout_ms);
static int send_command(const char *cmd, size_t len);
static void encode_ok(ei_x_buff *response, const char *data, int data_len);
static void encode_error(ei_x_buff *response, const char *reason);

#define BUFSIZE 65536
#define PROMPT "Maude>"
#define PROMPT_LEN 6

/* Maude process state */
typedef struct {
    pid_t pid;
    int stdin_fd;
    int stdout_fd;
    char buffer[BUFSIZE];
    int buffer_len;
} MaudeProcess;

static MaudeProcess maude = {0};
static volatile sig_atomic_t running = 1;

/* Signal handler for graceful shutdown */
static void handle_signal(int sig) {
    (void)sig;
    running = 0;
}

/* Set file descriptor to non-blocking mode */
static int set_nonblocking(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags == -1) return -1;
    return fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

/* Start the Maude subprocess */
static int start_maude(const char *maude_path) {
    int stdin_pipe[2], stdout_pipe[2];

    if (pipe(stdin_pipe) < 0 || pipe(stdout_pipe) < 0) {
        perror("pipe");
        return -1;
    }

    maude.pid = fork();
    if (maude.pid < 0) {
        perror("fork");
        return -1;
    }

    if (maude.pid == 0) {
        /* Child process */
        close(stdin_pipe[1]);
        close(stdout_pipe[0]);

        dup2(stdin_pipe[0], STDIN_FILENO);
        dup2(stdout_pipe[1], STDOUT_FILENO);
        dup2(stdout_pipe[1], STDERR_FILENO);

        close(stdin_pipe[0]);
        close(stdout_pipe[1]);

        /* Execute Maude with options to suppress banner and enable interactive mode */
        execl(maude_path, "maude", "-no-banner", "-no-wrap", "-no-advise", "-interactive", NULL);

        /* If execl fails */
        perror("execl");
        _exit(1);
    }

    /* Parent process */
    close(stdin_pipe[0]);
    close(stdout_pipe[1]);

    maude.stdin_fd = stdin_pipe[1];
    maude.stdout_fd = stdout_pipe[0];
    maude.buffer_len = 0;

    /* Set stdout to non-blocking for select() */
    set_nonblocking(maude.stdout_fd);

    return 0;
}

/* Stop the Maude subprocess */
static void stop_maude(void) {
    if (maude.pid > 0) {
        /* Send quit command (ignore errors during shutdown) */
        const char *quit_cmd = "quit\n";
        (void)write(maude.stdin_fd, quit_cmd, strlen(quit_cmd));

        /* Give it a moment to exit gracefully */
        usleep(100000);

        /* Force kill if still running */
        kill(maude.pid, SIGTERM);
        waitpid(maude.pid, NULL, 0);

        close(maude.stdin_fd);
        close(maude.stdout_fd);
        maude.pid = 0;
    }
}

/* Send command to Maude */
static int send_command(const char *cmd, size_t len) {
    ssize_t written = write(maude.stdin_fd, cmd, len);
    if (written < 0) {
        perror("write to maude");
        return -1;
    }

    /* Ensure command ends with newline */
    if (len == 0 || cmd[len - 1] != '\n') {
        if (write(maude.stdin_fd, "\n", 1) < 0) {
            perror("write newline to maude");
            return -1;
        }
    }

    return 0;
}

/* Read from Maude until we see the prompt
 * Returns: >= 0 on success (number of output bytes before prompt)
 *          -1 on timeout (no prompt found)
 *          -2 on read error
 *          -3 on EOF (Maude closed)
 */
static int read_until_prompt(char *output, int max_len, int timeout_ms) {
    int total = 0;
    fd_set readfds;
    struct timeval tv;
    int prompt_check_start;
    int prompt_found = 0;

    while (total < max_len - 1) {
        FD_ZERO(&readfds);
        FD_SET(maude.stdout_fd, &readfds);

        tv.tv_sec = timeout_ms / 1000;
        tv.tv_usec = (timeout_ms % 1000) * 1000;

        int ready = select(maude.stdout_fd + 1, &readfds, NULL, NULL, &tv);

        if (ready < 0) {
            if (errno == EINTR) continue;
            perror("select");
            output[total] = '\0';
            return -2;  /* Read error */
        }

        if (ready == 0) {
            /* Timeout - no more data available */
            break;
        }

        char buf[4096];
        ssize_t n = read(maude.stdout_fd, buf, sizeof(buf));

        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) continue;
            perror("read from maude");
            output[total] = '\0';
            return -2;  /* Read error */
        }

        if (n == 0) {
            /* EOF - Maude closed */
            output[total] = '\0';
            return -3;
        }

        /* Append to output buffer */
        int copy_len = (total + n > max_len - 1) ? (max_len - 1 - total) : (int)n;
        memcpy(output + total, buf, copy_len);
        total += copy_len;

        /* Check for prompt at end of buffer */
        prompt_check_start = (total > PROMPT_LEN) ? (total - PROMPT_LEN) : 0;
        output[total] = '\0';

        if (strstr(output + prompt_check_start, PROMPT) != NULL) {
            /* Found prompt, remove it from output */
            char *prompt_pos = strstr(output, PROMPT);
            if (prompt_pos != NULL) {
                *prompt_pos = '\0';
                total = (int)(prompt_pos - output);
            }
            prompt_found = 1;
            break;
        }
    }

    output[total] = '\0';

    /* Trim leading/trailing whitespace */
    while (total > 0 && (output[total-1] == '\n' || output[total-1] == '\r' || output[total-1] == ' ')) {
        output[--total] = '\0';
    }

    char *start = output;
    while (*start == '\n' || *start == '\r' || *start == ' ') {
        start++;
    }

    if (start != output) {
        memmove(output, start, strlen(start) + 1);
        total = (int)strlen(output);
    }

    if (!prompt_found) {
        return -1;  /* Timeout without finding prompt */
    }

    return total;  /* Success - return output length (may be 0) */
}

/* Wait for initial Maude prompt after startup */
static int wait_for_ready(void) {
    char buf[BUFSIZE];
    
    /* With -no-banner, Maude may not output anything until we send a command.
     * Send a simple newline to trigger the prompt. */
    (void)write(maude.stdin_fd, "\n", 1);
    
    int result = read_until_prompt(buf, BUFSIZE, 10000);
    if (result >= 0) {
        fprintf(stderr, "Maude ready (startup output %d bytes): '%s'\n", result, buf);
    } else if (result == -1) {
        fprintf(stderr, "Maude startup: timeout waiting for prompt (no 'Maude>' found)\n");
        fprintf(stderr, "Partial output received: '%s'\n", buf);
    } else if (result == -2) {
        fprintf(stderr, "Maude startup: read error\n");
    } else if (result == -3) {
        fprintf(stderr, "Maude startup: process closed (EOF)\n");
    }
    return result;
}

/* Encode an Erlang ok tuple: {:ok, data} */
static void encode_ok(ei_x_buff *response, const char *data, int data_len) {
    ei_x_encode_tuple_header(response, 2);
    ei_x_encode_atom(response, "ok");
    ei_x_encode_binary(response, data, data_len);
}

/* Encode an Erlang error tuple: {:error, reason} */
static void encode_error(ei_x_buff *response, const char *reason) {
    ei_x_encode_tuple_header(response, 2);
    ei_x_encode_atom(response, "error");
    ei_x_encode_atom(response, reason);
}

/* Handle incoming Erlang message */
static void handle_message(int fd, erlang_msg *emsg, ei_x_buff *buf) {
    int index = 0;
    int version;
    char cmd[256];
    int arity;

    ei_x_buff response;
    ei_x_new_with_version(&response);

    /* Decode version */
    if (ei_decode_version(buf->buff, &index, &version) < 0) {
        encode_error(&response, "decode_version_failed");
        goto send_response;
    }

    /* Decode tuple header */
    if (ei_decode_tuple_header(buf->buff, &index, &arity) < 0) {
        /* Not a tuple, check if it's just an atom (like :ping) */
        index = 0;
        ei_decode_version(buf->buff, &index, &version);

        if (ei_decode_atom(buf->buff, &index, cmd) == 0) {
            if (strcmp(cmd, "ping") == 0) {
                ei_x_encode_atom(&response, "pong");
                goto send_response;
            } else if (strcmp(cmd, "stop") == 0) {
                running = 0;
                ei_x_encode_atom(&response, "ok");
                goto send_response;
            }
        }

        encode_error(&response, "invalid_message_format");
        goto send_response;
    }

    /* Decode command atom */
    if (ei_decode_atom(buf->buff, &index, cmd) < 0) {
        encode_error(&response, "decode_command_failed");
        goto send_response;
    }

    if (strcmp(cmd, "execute") == 0) {
        /* Decode command binary */
        int type, size;
        if (ei_get_type(buf->buff, &index, &type, &size) < 0) {
            encode_error(&response, "get_type_failed");
            goto send_response;
        }

        char *command = malloc(size + 1);
        if (!command) {
            encode_error(&response, "malloc_failed");
            goto send_response;
        }

        long bin_size;
        if (ei_decode_binary(buf->buff, &index, command, &bin_size) < 0) {
            free(command);
            encode_error(&response, "decode_binary_failed");
            goto send_response;
        }
        command[bin_size] = '\0';

        /* Send command to Maude */
        if (send_command(command, bin_size) < 0) {
            free(command);
            encode_error(&response, "send_failed");
            goto send_response;
        }
        free(command);

        /* Read response (30 second timeout) */
        char output[BUFSIZE];
        int out_len = read_until_prompt(output, BUFSIZE, 30000);

        if (out_len < 0) {
            encode_error(&response, "read_failed");
        } else {
            encode_ok(&response, output, out_len);
        }

    } else if (strcmp(cmd, "ping") == 0) {
        ei_x_encode_atom(&response, "pong");

    } else if (strcmp(cmd, "stop") == 0) {
        running = 0;
        ei_x_encode_atom(&response, "ok");

    } else if (strcmp(cmd, "load_file") == 0) {
        /* Decode file path */
        int type, size;
        ei_get_type(buf->buff, &index, &type, &size);

        char *path = malloc(size + 16);  /* Extra for "load " prefix */
        if (!path) {
            encode_error(&response, "malloc_failed");
            goto send_response;
        }

        strcpy(path, "load ");
        long bin_size;
        if (ei_decode_binary(buf->buff, &index, path + 5, &bin_size) < 0) {
            free(path);
            encode_error(&response, "decode_path_failed");
            goto send_response;
        }
        path[5 + bin_size] = '\0';

        /* Send load command to Maude */
        if (send_command(path, strlen(path)) < 0) {
            free(path);
            encode_error(&response, "load_send_failed");
            goto send_response;
        }
        free(path);

        /* Read response */
        char output[BUFSIZE];
        int out_len = read_until_prompt(output, BUFSIZE, 30000);

        if (out_len < 0) {
            encode_error(&response, "load_read_failed");
        } else {
            /* Check for errors in output */
            if (strstr(output, "Error") != NULL || strstr(output, "Warning") != NULL) {
                ei_x_encode_tuple_header(&response, 2);
                ei_x_encode_atom(&response, "error");
                ei_x_encode_binary(&response, output, out_len);
            } else {
                ei_x_encode_atom(&response, "ok");
            }
        }

    } else {
        encode_error(&response, "unknown_command");
    }

send_response:
    ei_send(fd, &emsg->from, response.buff, response.index);
    ei_x_free(&response);
}

/* Connect to Erlang node with retry logic and exponential backoff */
static int connect_with_retry(ei_cnode *ec, char *nodename, int max_retries) {
    int fd;
    int delay_ms = 100;  /* Start with 100ms */
    
    for (int attempt = 1; attempt <= max_retries; attempt++) {
        fd = ei_connect_tmo(ec, nodename, 5000);  /* 5 second timeout per attempt */
        if (fd >= 0) {
            return fd;  /* Success */
        }
        
        fprintf(stderr, "Connection attempt %d/%d failed (errno: %d), retrying in %dms...\n",
                attempt, max_retries, erl_errno, delay_ms);
        
        usleep(delay_ms * 1000);  /* Convert to microseconds */
        delay_ms *= 2;  /* Exponential backoff */
        if (delay_ms > 2000) delay_ms = 2000;  /* Cap at 2 seconds */
    }
    
    return -1;  /* All retries exhausted */
}

/* Main entry point */
int main(int argc, char **argv) {
    if (argc < 5) {
        fprintf(stderr, "Usage: %s <node_name> <cookie> <maude_path> <erlang_node>\n", argv[0]);
        fprintf(stderr, "\n");
        fprintf(stderr, "Arguments:\n");
        fprintf(stderr, "  node_name    - Name for this C-Node (e.g., maude_bridge_1)\n");
        fprintf(stderr, "  cookie       - Erlang distribution cookie\n");
        fprintf(stderr, "  maude_path   - Path to Maude executable\n");
        fprintf(stderr, "  erlang_node  - Full Erlang node name to connect to\n");
        return 1;
    }

    char *node_name = argv[1];
    char *cookie = argv[2];
    char *maude_path = argv[3];
    char *erlang_node = argv[4];

    /* Setup signal handlers */
    signal(SIGTERM, handle_signal);
    signal(SIGINT, handle_signal);
    signal(SIGPIPE, SIG_IGN);

    /* Initialize ei library (required since OTP 21) */
    if (ei_init() != 0) {
        fprintf(stderr, "Failed to initialize ei library\n");
        return 1;
    }

    /* Start Maude subprocess */
    fprintf(stderr, "Starting Maude: %s\n", maude_path);
    if (start_maude(maude_path) < 0) {
        fprintf(stderr, "Failed to start Maude\n");
        return 1;
    }

    /* Wait for Maude to be ready */
    fprintf(stderr, "Waiting for Maude ready...\n");
    fflush(stderr);
    int ready_result = wait_for_ready();
    fprintf(stderr, "wait_for_ready returned: %d\n", ready_result);
    fflush(stderr);
    if (ready_result < 0) {
        fprintf(stderr, "Maude did not become ready\n");
        stop_maude();
        return 1;
    }
    fprintf(stderr, "Maude ready\n");
    fflush(stderr);

    /* Initialize C-Node */
    ei_cnode ec;
    char full_node_name[256];
    /* Extract hostname from erlang_node (e.g., "test@studio" -> "studio") */
    char hostname[128] = "localhost";
    char *at_sign = strchr(erlang_node, '@');
    if (at_sign != NULL) {
        strncpy(hostname, at_sign + 1, sizeof(hostname) - 1);
        hostname[sizeof(hostname) - 1] = '\0';
    }
    snprintf(full_node_name, sizeof(full_node_name), "%s@%s", node_name, hostname);

    if (ei_connect_init(&ec, node_name, cookie, 0) < 0) {
        fprintf(stderr, "Failed to init C-Node connection\n");
        stop_maude();
        return 1;
    }

    /* Connect to Erlang node with retry logic */
    fprintf(stderr, "Connecting to Erlang node: %s (with retry)\n", erlang_node);
    int fd = connect_with_retry(&ec, erlang_node, 5);  /* 5 retries */
    if (fd < 0) {
        fprintf(stderr, "Failed to connect to Erlang node after 5 retries: %s (errno: %d)\n", 
                erlang_node, erl_errno);
        stop_maude();
        return 1;
    }
    fprintf(stderr, "Connected to Erlang node\n");

    /* Signal ready to parent process */
    printf("READY\n");
    fflush(stdout);

    /* Main message loop */
    erlang_msg emsg;
    ei_x_buff buf;
    ei_x_new(&buf);

    while (running) {
        /* Use timeout variant - handles select internally */
        int got = ei_xreceive_msg_tmo(fd, &emsg, &buf, 1000);  /* 1 second timeout */

        if (got == ERL_TICK) {
            /* Heartbeat, ignore */
            continue;
        } else if (got == ERL_ERROR) {
            if (erl_errno == ETIMEDOUT) {
                /* Timeout is normal, check running flag and continue */
                continue;
            }
            fprintf(stderr, "Connection error (errno: %d)\n", erl_errno);
            break;
        } else if (got == ERL_MSG) {
            handle_message(fd, &emsg, &buf);
            ei_x_free(&buf);
            ei_x_new(&buf);
        }
    }

    /* Cleanup */
    fprintf(stderr, "Shutting down...\n");
    ei_x_free(&buf);
    close(fd);
    stop_maude();

    fprintf(stderr, "Goodbye\n");
    return 0;
}
