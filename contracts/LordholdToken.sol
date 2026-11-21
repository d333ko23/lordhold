// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Lordhold (LHOLD token)
/// @notice BEP-20 token for Lordhold, the medieval kingdom game
///         on BNB Chain. Fixed supply of 1,000,000,000 LHOLD, minted
///         in full to the deployer at deployment. There is no mint
///         function: the supply can never grow.
///
///         Transfers are OPEN from the first second. No transfer
///         lock, no unlock milestone, no whitelist, no tax.
///
///         Distribution happens out of the deployer's wallet after
///         deployment: the 300,000,000 LHOLD Season 1 emission
///         pocket locked into the Lordhold NFT contract, the
///         PancakeSwap V3 LHOLD/USDT pool stack (the pool is
///         created on day 3 after the NFT mint opens, funded by
///         the mint fees of the first three days), and the
///         remainder held as treasury / next-season reserve. Those
///         moves are ordinary transfers, visible on-chain.
contract LordholdToken {
    // ---------------- BEP-20 metadata ----------------
    string public name = "Lordhold";
    string public symbol = "LHOLD";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;

    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 1e18;

    // ---------------- State ----------------
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // ---------------- Events ----------------
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner_, address indexed spender, uint256 value);

    constructor() {
        totalSupply = TOTAL_SUPPLY;
        balanceOf[msg.sender] = TOTAL_SUPPLY;
        emit Transfer(address(0), msg.sender, TOTAL_SUPPLY);
    }

    // ---------------- BEP-20 core ----------------
    function transfer(address to, uint256 amount) public returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) public returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance too low");
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    /// @notice Plain open transfer. No lock, no gate, no fee.
    function _transfer(address from, address to, uint256 amount) internal {
        require(to != address(0), "zero to");
        require(balanceOf[from] >= amount, "balance too low");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}
