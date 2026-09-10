# Deployment records

One file per chain id. The deploy script writes it; the website and the services read it.

```jsonc
{
  "chainId": 46630,
  "network": "robinhood-testnet",
  "deployedAt": "2026-09-10T12:00:00Z",     // ISO 8601, or null before deployment
  "commit": "0000000",                       // packages/contracts commit that produced the bytecode
  "contracts": {
    "KAY9Token":          "0x…",
    "KAY9TeamVesting":    "0x…",
    "KAY9Genesis":        "0x…",
    "KAY9LiquidityLock":  "0x…",
    "KAY9AuditorRegistry":"0x…",
    "KAY9Pricing":        "0x…",
    "KAY9Registry":       "0x…",
    "KAY9AuditHub":       "0x…",
    "Timelock":           "0x…",
    "Treasury":           "0x…",
    "Auction":            "0x…"              // current CCA, optional; also readable from Genesis.auction()
  },
  "codeHashes": {
    "KAY9Token": "0x…"                       // keccak256(eth_getCode) at deployment; /transparency compares live
  }
}
```

Any key that is missing resolves to `zeroAddress` and `isDeployed(chainId)` stays `false`.
