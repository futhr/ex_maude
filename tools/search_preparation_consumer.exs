# Stage the public preparation fixture beside this script in the minimal host.
ExUnit.start(seed: 20_261_005, include: [:integration])
Code.require_file("preparation_test.exs", __DIR__)
