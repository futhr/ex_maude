Benchmark

## Concurrency Benchmarks

Validates worker pool provides expected concurrency benefits.
With pool_size: 4, parallel execution should show significant speedup.


## System

Benchmark suite executing on the following system:

<table style="width: 1%">
  <tr>
    <th style="width: 1%; white-space: nowrap">Operating System</th>
    <td>macOS</td>
  </tr><tr>
    <th style="white-space: nowrap">CPU Information</th>
    <td style="white-space: nowrap">Apple M4 Max</td>
  </tr><tr>
    <th style="white-space: nowrap">Number of Available Cores</th>
    <td style="white-space: nowrap">16</td>
  </tr><tr>
    <th style="white-space: nowrap">Available Memory</th>
    <td style="white-space: nowrap">128 GB</td>
  </tr><tr>
    <th style="white-space: nowrap">Elixir Version</th>
    <td style="white-space: nowrap">1.19.5</td>
  </tr><tr>
    <th style="white-space: nowrap">Erlang Version</th>
    <td style="white-space: nowrap">28.2</td>
  </tr>
</table>

## Configuration

Benchmark suite executing with the following configuration:

<table style="width: 1%">
  <tr>
    <th style="width: 1%">:time</th>
    <td style="white-space: nowrap">10 s</td>
  </tr><tr>
    <th>:parallel</th>
    <td style="white-space: nowrap">1</td>
  </tr><tr>
    <th>:warmup</th>
    <td style="white-space: nowrap">2 s</td>
  </tr>
</table>

## Statistics



Run Time

<table style="width: 1%">
  <tr>
    <th>Name</th>
    <th style="text-align: right">IPS</th>
    <th style="text-align: right">Average</th>
    <th style="text-align: right">Devitation</th>
    <th style="text-align: right">Median</th>
    <th style="text-align: right">99th&nbsp;%</th>
  </tr>

  <tr>
    <td style="white-space: nowrap">parallel 5 reduces</td>
    <td style="white-space: nowrap; text-align: right">8.68 K</td>
    <td style="white-space: nowrap; text-align: right">115.21 &micro;s</td>
    <td style="white-space: nowrap; text-align: right">&plusmn;9.38%</td>
    <td style="white-space: nowrap; text-align: right">113.75 &micro;s</td>
    <td style="white-space: nowrap; text-align: right">144.30 &micro;s</td>
  </tr>

  <tr>
    <td style="white-space: nowrap">sequential 5 reduces</td>
    <td style="white-space: nowrap; text-align: right">7.46 K</td>
    <td style="white-space: nowrap; text-align: right">134.13 &micro;s</td>
    <td style="white-space: nowrap; text-align: right">&plusmn;5.88%</td>
    <td style="white-space: nowrap; text-align: right">132.96 &micro;s</td>
    <td style="white-space: nowrap; text-align: right">155.21 &micro;s</td>
  </tr>

</table>


Run Time Comparison

<table style="width: 1%">
  <tr>
    <th>Name</th>
    <th style="text-align: right">IPS</th>
    <th style="text-align: right">Slower</th>
  <tr>
    <td style="white-space: nowrap">parallel 5 reduces</td>
    <td style="white-space: nowrap;text-align: right">8.68 K</td>
    <td>&nbsp;</td>
  </tr>

  <tr>
    <td style="white-space: nowrap">sequential 5 reduces</td>
    <td style="white-space: nowrap; text-align: right">7.46 K</td>
    <td style="white-space: nowrap; text-align: right">1.16x</td>
  </tr>

</table>