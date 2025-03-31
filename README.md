# Pump-fun-on-aptos

## Contract Link

```
https://explorer.movementnetwork.xyz/account/0x4070b42af7f923a0dcef7764b9a8bb613cc4a5fb59b6f9b4d81d11384ed0745b/transactions?network=testnet
```

## Token Template

```move
module 0x7f3d4f0094a49421bdfca03366fa02add69d9091c76a4a0fe498caa163886fc0::AASS {
    struct AASS {}
}
```

Note: You need to replace:
- The `0x` part with your wallet address
- `AASS` (in both places) with your symbol
After compiling, return to the frontend, and the frontend will publish a tx to the blockchain to deploy the token contract.

## Deploying PumpFun and Buying Simultaneously

```move
entry public fun deploy<CoinType>(
    caller: &signer,
    description: String,
    name: String,
    symbol: String,
    uri: String,
    website: String,
    telegram: String,
    twitter: String,
)
```

Parameters and types (fill in as directed):
- description: String
- name: String
- symbol: String
- uri: String
- website: String
- telegram: String
- twitter: String

You'll need one type argument - fill in with the Token address you created in the previous step:
```
0x7f3d4f0094a49421bdfca03366fa02add69d9091c76a4a0fe498caa163886fc0::AASS::AASS
```

### Deploy and Buy Function

```move
entry public fun deploy_and_buy<CoinType>(
    caller: &signer,
    out_amount: u64,
    description: String,
    name: String,
    symbol: String,
    uri: String,
    website: String,
    telegram: String,
    twitter: String,
)
```

This adds one new parameter compared to `deploy`: `out_amount` as the first parameter.

## Buy Function

```move
public entry fun buy<CoinType>(
    caller: &signer,
    out_amount: u64
)
```

Just one parameter: the number of tokens to buy (`out_amount`).

You'll need one type argument - fill in with the Token address you created:
```
0x7f3d4f0094a49421bdfca03366fa02add69d9091c76a4a0fe498caa163886fc0::AASS::AASS
```

## Sell Function

```move
public entry fun sell<CoinType>(
    caller: &signer, 
    out_amount: u64
)
```

Similar to the buy function.
`out_amount` is the amount of APT to receive. It can match the estimated amount or be multiplied by a slippage factor to ensure success.

You'll need one type argument - fill in with the Token address you created:
```
0x7f3d4f0094a49421bdfca03366fa02add69d9091c76a4a0fe498caa163886fc0::AASS::AASS
```
