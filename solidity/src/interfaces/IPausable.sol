// SPDX-License-Identifier: Apache 2

pragma solidity ^0.8.0;

interface IPausable {
    function paused() external view returns (bool);
}
