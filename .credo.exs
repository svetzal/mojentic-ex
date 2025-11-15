%{
  configs: [
    %{
      name: "default",
      strict: true,
      checks: [
        # Additional and reconfigured checks
        {Credo.Check.Design.AliasUsage,
          if_nested_deeper_than: 3,
          if_called_more_often_than: 1},
        {Credo.Check.Readability.AliasAs, false},
        {Credo.Check.Readability.AliasOrder, false},
        {Credo.Check.Readability.MultiAlias, false},
        {Credo.Check.Readability.NestedFunctionCalls, false},
        {Credo.Check.Readability.PreferImplicitTry, false},
        {Credo.Check.Readability.SeparateAliasRequire, []},
        {Credo.Check.Readability.SinglePipe, false},
        {Credo.Check.Readability.StrictModuleLayout, []},
        {Credo.Check.Readability.WithCustomTaggedTuple, []},
        {Credo.Check.Refactor.ABCSize, [max_size: 75]},
        {Credo.Check.Refactor.CyclomaticComplexity, [max_complexity: 15]},
        {Credo.Check.Warning.UnsafeToAtom, []},

        # Disabled checks
        {Credo.Check.Design.TagFIXME, false},
        {Credo.Check.Design.TagTODO, false},
        {Credo.Check.Readability.ModuleDoc, false},
        {Credo.Check.Refactor.LongQuoteBlocks, false},
        {Credo.Check.Refactor.Nesting, false}
      ]
    }
  ]
}
