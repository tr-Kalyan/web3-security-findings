// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockFaucet is ERC20 {
    uint256 constant INITIAL_SUPPLY = 1_000_000_000 * 10**18;

    constructor() ERC20("FaucetToken", "FTK") {
        _mint(address(this), INITIAL_SUPPLY);
    }

    // VULNERABLE: Drains entire balance before burning
    function burnFaucetTokens(uint256 amountToBurn) public {
        require(amountToBurn <= balanceOf(address(this)), "Insufficient balance");

        // Drains ALL tokens to caller (owner in real contract)
        _transfer(address(this), msg.sender, balanceOf(address(this)));

        // Burns only the requested amount from caller's balance
        _burn(msg.sender, amountToBurn);
    }
}