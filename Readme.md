# BondFlow — On-Chain Architecture & Logic (Arbitrum)

BondFlow is a fully on-chain, automated bond engine deployed on **Arbitrum One**. The protocol architecture consists of two autonomous smart contracts:

* The **Engine**, which manages bond lifecycle, principal activation, protocol TVL accounting, and internal flows.
* The **Vault Pool**, which automates Uniswap v3 liquidity management, fee collection, and on-demand USDC provisioning to the Engine.

This README documents **only the on-chain architecture and logic**, without frontend references or off-chain systems.

---

## 🧩 Core Smart Contracts

### **1. BondFlow Engine (Core Protocol)**

**Address:** `0xf829F25735b7257013C97Cf43690DB65E1A02e60`
**Arbiscan:** [https://arbiscan.io/address/0xf829F25735b7257013C97Cf43690DB65E1A02e60](https://arbiscan.io/address/0xf829F25735b7257013C97Cf43690DB65E1A02e60)

The Engine is the central logic unit of BondFlow. It is responsible for:

* Managing user bond purchases and expirations.
* Tracking the protocol’s **true TVL**: `totalPrincipalActive`.
* Routing internal yield or inflows.
* Determining how much principal should be allocated to the Vault (`vaultAllocBps`).
* Requesting USDC from the Vault when liquidity is required.

**Engine responsibilities:**

* Register principal deposits.
* Maintain bond lifecycle and internal accounting.
* Communicate with the Vault for liquidity requests.
* Hold an accurate, on-chain measure of active principal.

The Engine does **not** manage external liquidity positions; it only governs protocol flows.

---

### **2. Vault Pool (Uniswap v3 Liquidity Manager)**

**Address:** `0x296f18B56554DBAD972b341FdC487EE5831C3b61`
**Arbiscan:** [https://arbiscan.io/address/0x296f18B56554DBAD972b341FdC487EE5831C3b61#code](https://arbiscan.io/address/0x296f18B56554DBAD972b341FdC487EE5831C3b61#code)

The Vault operates as an autonomous liquidity engine. It manages:

#### 🔹 Uniswap v3 concentrated liquidity

* Two NFT positions: **Low range** and **High range**.
* Full support for mint/increase/decrease liquidity.
* Complete rebalance execution (closing → collecting fees → opening new position).

#### 🔹 Fee accounting

The Vault internally tracks:

* USDC fees from low/high ranges
* WETH fees from low/high ranges
* Extra USDC fees (manually added inflows)

All fees are stored on-chain:

```
feesOwedUsdcLow
feesOwedWethLow
feesOwedUsdcHigh
feesOwedWethHigh
feesOwedUsdcExtra
```

#### 🔹 Automated WETH → USDC conversion

When the Engine needs USDC, the Vault:

1. Removes liquidity (partially or fully).
2. Collects fees.
3. Swaps WETH → USDC via Uniswap v3.
4. Sends exact USDC amount back to the Engine.

This allows the Vault to operate independently while ensuring Engine liquidity at all times.

#### 🔹 Intelligent rebalance support

The Vault can:

* Close the current NFT
* Collect all fees
* Open a new position in a new tick range
* Update internal accounting accordingly

---

## 🔍 On-Chain Flow Architecture

### **1. User deposits principal into a bond (Engine)**

* Principal is added to `totalPrincipalActive`.
* Engine decides how much should be allocated to the Vault.

### **2. Engine sends USDC to Vault**

* These funds become available for liquidity deployment.
* Operator manages Uniswap v3 strategy.

### **3. Vault deploys liquidity in Uniswap v3**

* Two NFT positions accumulate USDC/WETH fees.
* Fees are accounted automatically and stored on-chain.

### **4. Engine requests liquidity when needed**

Vault automatically:

* Removes liquidity
* Collects fees
* Swaps WETH → USDC
* Transfers exact USDC amount requested

### **5. Engine performs bond settlements or internal operations**

The Engine uses received USDC for:

* Bond expirations
* Internal protocol flows

---

## 📡 Public Functions of Interest

### **Vault Pool**

* `getVaultBalances()` → Liquid USDC/WETH in the Vault
* `getFeesOwedRaw()` → All fee buckets
* `positionIdUsdcWethLow()` → Active low-range NFT ID
* `positionIdUsdcWethHigh()` → Active high-range NFT ID
* `rebalanceToNewLow()` → Full rebalance procedure
* `decreaseAndCollectLow/High()` → Partial liquidity removal
* `provideLiquidity()` → Called by Engine to supply USDC

### **Engine**

* `totalPrincipalActive()` → Protocol TVL (real, principal-based)
* `getGlobalStats()` → Aggregated system view
* `pullFromVault()` / `onEnginePull()` → Vault → Engine integrations

---

## 🎯 Design Goals

### **Fully on-chain**

Every operation—liquidity management, fees, accounting, rebalancing—is executed by smart contracts.

### **Transparent & verifiable**

All logic is visible:

* Principal activation
* Fee generation
* Transfer flows
* Liquidity changes
* Range updates and rebalances

### **Modular architecture**

Engine and Vault are independent:

* Engine manages principal & bonds
* Vault manages liquidity & yield generation

---

## 🛡 Security & Permissions

* **Engine** and **Operator** have defined, limited responsibilities.
* Vault funds can only move through protocol-defined routes.
* No contract can arbitrarily withdraw funds to external wallets.
* Vault may only send USDC back to the Engine.

No functions exist that give external control over user funds.

---

## 📚 Official Links

* **BondFlow Engine:** [https://arbiscan.io/address/0xf829F25735b7257013C97Cf43690DB65E1A02e60](https://arbiscan.io/address/0xf829F25735b7257013C97Cf43690DB65E1A02e60)
* **Vault Pool:** [https://arbiscan.io/address/0x296f18B56554DBAD972b341FdC487EE5831C3b61#code](https://arbiscan.io/address/0x296f18B56554DBAD972b341FdC487EE5831C3b61#code)

---

