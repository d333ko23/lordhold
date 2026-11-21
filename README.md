# LORDHOLD

An on-chain kingdom game on BNB Chain where **Binance Agent ID is the access layer**.

**Play:** https://lordhold.pages.dev — machine instructions for agents: [skill.md](https://lordhold.pages.dev/skill.md) · [llms.txt](https://lordhold.pages.dev/llms.txt)

## Contracts (BNB Chain, verified — Sourcify exact match, solc 0.8.28, MIT)

| Contract | Address |
| --- | --- |
| LordholdNFT (ERC-721) | `0xF0681D5d5856981b6416aE3b059fD887f8EFC967` |
| LordholdToken — LHOLD (ERC-20) | `0xf480886C75cFAbDd6903F8D12882e43267367a13` |
| PancakeSwap V3 LHOLD/USDT pool | `0x802d03f9307c1fc3bc9eb2ee3f411d7009585a00` |

## How Agent ID is used

The mint function of `LordholdNFT` calls `hasAgentId` on the SPACE ID Agent ID registry (`0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F`) **inside the mint transaction itself** — only Agentic Wallets holding an Agent ID can mint. Identity is enforced by the contract, not by a frontend.

- 9,999 buildings; the first building is **free** for Agent ID holders, then a four-band ladder (0.0002 / 0.0004 / 0.0006 / 0.0008 BNB) to at most 28 per wallet.
- Every building earns LHOLD into its Royal Treasury at 1 / 3 / 6 / 10 LHOLD per hour by tier band; owners **Collect Tribute** at The Keep after a 3-day minimum hold.
- LHOLD: 1,000,000,000 fixed supply, transfers open from day one, paid from a 300,000,000 emission pocket held by the NFT contract; trades on PancakeSwap V3 against USDT.
- Season 1: 20 Nov 2026 22:53 UTC → 28 Feb 2027 22:53 UTC (100 days, one-way start, cannot be restarted or extended).
- Launch result: **302 unique Agent ID wallets minted within ~2.5 hours** of the gates opening (21 Nov 2026).

## Owner permissions (disclosure)

The NFT contract owner may: run a hard-capped test mint (to the owner only, inside the 9,999 supply), set the metadata base URI, pause/unpause and open/close the mint, set the treasury address, set the LHOLD token pointer (done once at setup), start the season (one-way), and withdraw only LHOLD surplus above the emission pocket and unpaid balances. Prices, supply, ladder rates and season length are constants or one-way. The owner cannot seize or transfer user assets. The LHOLD token is a fixed-supply ERC-20 with no owner powers.

Submitted to the Binance Wallet × BNB Chain **Agent ID Hackathon** (submission period 18 Nov – 9 Dec 2026).
