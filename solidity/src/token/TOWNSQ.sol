// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

contract TOWNSQ is ERC20Upgradeable {
    /**
     * @notice contract constructor; prevent initialize() from being invoked on the implementation contract
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev contract initializer
     */
    function initialize() public initializer {
        ERC20Upgradeable.__ERC20_init("Townsq Finance", "TOWNSQ");

        _mint(msg.sender, 800_000_000 ether);
    }

    function burn(uint256 _amount) external {
        _burn(msg.sender, _amount);
    }
}
