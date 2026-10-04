#region ENCODING
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding           = [System.Text.Encoding]::UTF8
} catch { <# namjerno: kodiranje konzole nije kritično; izvodi se prije definicije Write-AppLog #> }
#endregion ENCODING

