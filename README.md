# Zircuit Finance — Performance-Fee PoC (H2)

Fork-based proof of concept for a fee-accounting issue in Zircuit Finance's
`AccountingReceiver` (Base): the 20% performance fee is charged on **every gross
positive delta** reported by a `StrategyManager`, with **no high-water mark, no
loss carry-forward, and no netting between reporting periods**. A recovery leg
that merely restores a previous loss — and even a third-party **donation** to a
strategy — is charged the full 20% as if it were new profit.

All tests run against the **deployed** contracts on a Base fork. No mocks of
the target contracts are used (a mock ERC-4626 serves only as the strategy
position, deployed through the real `StrategyManager`).

## Key results (Base fork, block 59,447,119)

- **Oscillation:** three ±10,000 USDC cycles on a 100,000 USDC position with
  exactly **zero net performance** minted **5,639,188,284 fee shares**
  (**5,949.760656 USDC**) and dragged PPS from 1.059509013769673869 to
  1.055073949860027574 (−0.4186%).
- **Donation:** a 10,000 USDC third-party donation to a strategy was charged
  the full 20% — **1,877,101,711 fee shares (≈ 1,999.999998 USDC)**; the donor
  received 0 shares and only 8,000 USDC of value accrued to depositors.
- Full suite: **31/31 tests PASS** (includes control cases showing a fee on
  genuine retained yield behaving correctly, plus the H1/H3, fee-signer and
  deep-dive validation suites from the same engagement).

Raw outputs are in [`outputs/`](outputs/) and are quoted verbatim in the
report.

## Layout

```
foundry.toml            solc 0.8.30, optimizer 200 runs; RPC endpoints for forks
src/MockStrategy.sol    mock ERC-4626 used as the strategy position
test/
  ZircuitValidation.t.sol   H1/H2 suite — testH2_OscillationFeeDrag (§5.1)
  ZircuitDonation.t.sol     donation case — testDonationChargedPerformanceFee (§5.2)
  ZircuitH3.t.sol           VaultComposer atomicity checks
  ZircuitFeeSigner.t.sol    fee-signer validation suite
  ZircuitDeepDive.t.sol     deep-dive suite
lib/forge-std/          vendored forge-std (so the suite runs as-is)
outputs/                raw `forge test` logs from the validation runs
```

## Run it

Requirements: Foundry `forge 1.9.0` (validated with build commit
`6056c5845d34205a83cf7108042adb137325c9df`), solc 0.8.30 (pinned in
`foundry.toml`), and network access to a Base RPC (the tests fork Base at
block **59,447,119** via the `base` endpoint in `foundry.toml`,
`https://mainnet.base.org` by default — any archive-capable Base RPC works).

```bash
forge test                                     # full suite — 31/31 PASS
forge test --match-test testH2_OscillationFeeDrag -vvv
forge test --match-contract ZircuitDonationTest -vvv
```

## Affected deployed contracts (Base)

| Contract | Address |
|---|---|
| AccountingReceiver (USDC) | `0x7fCeB53b2959861D29057361158a2B41cAAffD68` |
| AccountingReceiver (USDT) | `0x43c4a95788997a3E02F6Ca7E5CC4c23dbDE66c9C` |
| AccountingReceiver implementation (shared) | `0xbFaebf5eAEAaC737E6D274D70e5C6AFA76410302` |
| StrategyManager (USDC) | `0xf7E745658fa6f1fe8f2CAb47861a273991Cd3374` |
| StrategyManager (USDT) | `0x075193D36693DA7BA3Bb709cF63bEf070BA04D94` |

## Testing statement

All validation was performed on local Foundry forks plus read-only on-chain
calls. **No mainnet transactions were sent and no protocol or user funds were
touched.** The donation test's "donation" was made with fork-dealt test funds
inside the local fork only.

Reporter contact: binasalama12@gmail.com
