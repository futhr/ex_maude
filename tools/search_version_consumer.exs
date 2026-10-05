# Stage the public version fixture beside this script in the minimal host.
ExUnit.start(seed: 20_261_005, include: [:integration])
Code.require_file("version_integration_test.exs", __DIR__)
