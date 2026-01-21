%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/"],
        excluded: [~r"/_build/", ~r"/deps/"]
      },
      plugins: [],
      requires: [],
      strict: true,
      parse_timeout: 5000,
      color: true,
      checks: %{
        enabled: [
          # Consistency checks
          {Credo.Check.Consistency.TabsOrSpaces, []},
          {Credo.Check.Consistency.LineEndings, []},
          {Credo.Check.Consistency.ParameterPatternMatching, []},
          {Credo.Check.Consistency.SpaceAroundOperators, []},
          {Credo.Check.Consistency.SpaceInParentheses, []},

          # Readability checks
          {Credo.Check.Readability.ModuleDoc, []},
          {Credo.Check.Readability.FunctionNames, []},
          {Credo.Check.Readability.Specs, []},
          {Credo.Check.Readability.MaxLineLength, [max_length: 120]},
          {Credo.Check.Readability.TrailingBlankLine, []},
          {Credo.Check.Readability.TrailingWhiteSpace, []},
          {Credo.Check.Readability.VariableNames, []},
          {Credo.Check.Readability.ParenthesesOnZeroArityDefs, []},
          {Credo.Check.Readability.ModuleNames, []},
          {Credo.Check.Readability.ParenthesesInCondition, []},
          {Credo.Check.Readability.WithSingleClause, []},

          # Refactoring opportunities
          {Credo.Check.Refactor.CondStatements, []},
          {Credo.Check.Refactor.CyclomaticComplexity, [max_complexity: 12]},
          {Credo.Check.Refactor.FunctionArity, [max_arity: 5]},
          {Credo.Check.Refactor.Nesting, [max_nesting: 3]},
          {Credo.Check.Refactor.WithClauses, []},
          {Credo.Check.Refactor.DoubleBooleanNegation, []},
          {Credo.Check.Refactor.RedundantWithClauseResult, []},

          # Warning checks
          {Credo.Check.Warning.BoolOperationOnSameValues, []},
          {Credo.Check.Warning.IExPry, []},
          {Credo.Check.Warning.IoInspect, []},
          {Credo.Check.Warning.MixEnv, []},
          {Credo.Check.Warning.OperationOnSameValues, []},
          {Credo.Check.Warning.RaiseInsideRescue, []},
          {Credo.Check.Warning.UnusedEnumOperation, []},
          {Credo.Check.Warning.UnusedKeywordOperation, []},
          {Credo.Check.Warning.UnusedListOperation, []},
          {Credo.Check.Warning.UnusedStringOperation, []},
          {Credo.Check.Warning.UnusedTupleOperation, []},
          {Credo.Check.Warning.UnusedFileOperation, []},
          {Credo.Check.Warning.UnusedPathOperation, []},
          {Credo.Check.Warning.UnusedRegexOperation, []},

          # Design checks
          {Credo.Check.Design.TagTODO, [exit_status: 0]},
          {Credo.Check.Design.TagFIXME, []},

          # Disabled checks (with reason)
          # AliasUsage - Too noisy for this codebase structure
          {Credo.Check.Design.AliasUsage, false},
          # LongQuoteBlocks - Maude commands can be lengthy
          {Credo.Check.Refactor.LongQuoteBlocks, false},
          # StrictModuleLayout - Allows flexibility in module organization
          {Credo.Check.Readability.StrictModuleLayout, false},
          # SinglePipe - Single-element pipes are common for readability in data transformations
          {Credo.Check.Readability.SinglePipe, false},
          # PipeChainStart - Regex.scan/run results are commonly piped
          {Credo.Check.Refactor.PipeChainStart, false},
          {Credo.Check.Readability.PredicateFunctionNames, []},
          # PreferImplicitTry - Explicit try can be clearer for error handling
          {Credo.Check.Readability.PreferImplicitTry, false},
          # ExpensiveEmptyEnumCheck - length == 0 patterns are often clearer in tests
          {Credo.Check.Warning.ExpensiveEmptyEnumCheck, false},
          # UnsafeToAtom - Whitelisted patterns are used (e.g., cnode name generation)
          {Credo.Check.Warning.UnsafeToAtom, false}
        ]
      }
    }
  ]
}
