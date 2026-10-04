BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . ([scriptblock]::Create((Get-AuxFunctionText 'ConvertFrom-DeepBytes', 'New-InfoItem')))
    function ConvertTo-DeepBytes { param([string]$Text) return ,[System.Text.Encoding]::UTF8.GetBytes($Text) }   # zarez: prazno polje se inače pretvara u $null
}

Describe 'ConvertFrom-DeepBytes' {
    It 'čita zadnji potpuni redak (kumulativni popis) i odbacuje nepoznate vrste' {
        $first = '[{"Kind":"Section","Label":"","Value":"DNEVNICI","Status":""}]'
        $last  = '[{"Kind":"Section","Label":"","Value":"DNEVNICI","Status":""},{"Kind":"KV","Label":"BSOD","Value":"0","Status":"Good"},{"Kind":"Bogus","Label":"x","Value":"y"}]'
        $items = @(ConvertFrom-DeepBytes (ConvertTo-DeepBytes ($first + "`n" + $last + "`n")))
        $items.Count | Should -Be 2
        $items[1].Label | Should -Be 'BSOD'
        $items[1].Status | Should -Be 'Good'
    }
    It 'prazan Status postaje Normal' {
        $items = @(ConvertFrom-DeepBytes (ConvertTo-DeepBytes ('[{"Kind":"Text","Label":"","Value":"t","Status":""}]' + "`n")))
        $items[0].Status | Should -Be 'Normal'
    }
    It '-Killed odbacuje napola ispisan zadnji redak' {
        $good = '[{"Kind":"Text","Label":"","Value":"cijeli","Status":"Normal"}]'
        $bytes = ConvertTo-DeepBytes ($good + "`n" + '[{"Kind":"Text","Label":"","Val')
        $items = @(ConvertFrom-DeepBytes $bytes -Killed)
        $items.Count | Should -Be 1
        $items[0].Value | Should -Be 'cijeli'
    }
    It 'bez -Killed nepotpun zadnji redak nije JSON i baca iznimku' {
        $bytes = ConvertTo-DeepBytes ('[{"Kind":"Text","Value":"a"}]' + "`n" + '[{"Kind":"Te')
        { ConvertFrom-DeepBytes $bytes } | Should -Throw
    }
    It 'prazan ulaz baca iznimku' {
        { ConvertFrom-DeepBytes (ConvertTo-DeepBytes '') } | Should -Throw 'nema potpunog retka*'
    }
    It 'hrvatski znakovi ostaju netaknuti (UTF-8)' {
        $items = @(ConvertFrom-DeepBytes (ConvertTo-DeepBytes ('[{"Kind":"KV","Label":"Šifriranje","Value":"đč","Status":"Good"}]' + "`n")))
        $items[0].Label | Should -Be 'Šifriranje'
        $items[0].Value | Should -Be 'đč'
    }
}
