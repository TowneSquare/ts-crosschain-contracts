// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {MockPyth as MockPythBase} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";

contract MockTestPyth is MockPythBase {
  constructor(uint _validTimePeriod, uint _singleUpdateFeeInWei) MockPythBase(_validTimePeriod, _singleUpdateFeeInWei) {}
}
