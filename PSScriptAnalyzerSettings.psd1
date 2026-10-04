# T0.3 - postavke PSScriptAnalyzera. Samo pravila koja pogađaju stvarne nalaze iz izvještaja o reviziji;
# pozicijski parametri, ShouldProcess i jednina imenica su šum za ovaj alat i ne uključuju se.
@{
    IncludeRules = @(
        'PSAvoidUsingEmptyCatchBlock',
        'PSUseDeclaredVarsMoreThanAssignments',
        'PSReviewUnusedParameter',
        'PSAvoidGlobalVars',
        'PSAvoidAssignmentToAutomaticVariable',
        'PSAvoidUsingCmdletAliases',
        'PSAvoidUsingInvokeExpression',
        'PSAvoidUsingWMICmdlet',
        'PSAvoidUsingPlainTextForPassword',
        'PSAvoidUsingConvertToSecureStringWithPlainText',
        'PSPossibleIncorrectComparisonWithNull'
    )
}
