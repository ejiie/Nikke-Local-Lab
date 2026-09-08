param([string]$Action, [string]$ReceiptPath)
if ($Action -cne 'loopback-verify') { throw 'synthetic_action_invalid' }
'{"contractId":"nll/resource-loopback-preflight/v1","statusCode":"verified","officialOutboundPerformed":false}'
exit 0
