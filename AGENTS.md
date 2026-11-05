# Repository instructions

Read [README.md](README.md), [CONTRIBUTING.md](CONTRIBUTING.md), the owning
contract and relevant source/tests before changing a mechanism. Preserve
unrelated work and local client settings. Never push Git refs or change
repository visibility; those actions remain user-managed.

## Skills and discovery

Shared skills live in `.agents/skills/<name>/SKILL.md`. Select matching skills
automatically from their descriptions and read the complete body before using
them. The user does not invoke skills manually. Keep implicit invocation enabled.
Use [security-review](.agents/skills/security-review/SKILL.md) for requested
security audits and changed command, subprocess/NIF, parser or installer trust
boundaries. Mathematical-model review alone does not select that workflow.

Codex discovers `.agents/skills` natively. Clients without native discovery must
inspect those descriptions and read the matching files themselves. Claude Code
uses ignored individual `.claude/skills/<name>` directory symlinks targeting
`../../.agents/skills/<name>`. Preserve local entries and repair only
repository-owned links. Keep client settings local; do not add hooks or wrappers.

Review requests produce findings unless repairs are authorized. Guidance-only
changes use metadata, reference, tracking/ignore, discovery and semantic routing
checks with existing tools; do not install a solver or dependencies to validate
instructions. Report source inspection, executed tests and actual solver/native
evidence separately. Application changes follow CONTRIBUTING's checks.
