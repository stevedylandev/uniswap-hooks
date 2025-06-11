// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BalanceDelta, toBalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {Test} from "forge-std/Test.sol";

// @dev Custom assertions for `BalanceDelta` from `v4-core`
contract BalanceDeltaAssertions is Test {
    // @dev Asserts that `delta1` is equal to `delta2` for both amount0 and amount1
    function assertEq(BalanceDelta delta1, BalanceDelta delta2) internal {
        assertEq(BalanceDeltaLibrary.amount1(delta1), BalanceDeltaLibrary.amount1(delta2));
        assertEq(BalanceDeltaLibrary.amount0(delta1), BalanceDeltaLibrary.amount0(delta2));
    }

    // @dev Asserts that `delta1` is equal to `delta2` for both amount0 and amount1 with a custom error message
    function assertEq(BalanceDelta delta1, BalanceDelta delta2, string memory err) internal {
        assertEq(BalanceDeltaLibrary.amount1(delta1), BalanceDeltaLibrary.amount1(delta2), err);
        assertEq(BalanceDeltaLibrary.amount0(delta1), BalanceDeltaLibrary.amount0(delta2), err);
    }

    // @dev Asserts that `delta1` is approximately equal to `delta2` for both amount0 and amount1
    function assertAproxEqAbs(BalanceDelta delta1, BalanceDelta delta2, uint256 absTolerance) internal {
        assertApproxEqAbs(BalanceDeltaLibrary.amount1(delta1), BalanceDeltaLibrary.amount1(delta2), absTolerance);
        assertApproxEqAbs(BalanceDeltaLibrary.amount0(delta1), BalanceDeltaLibrary.amount0(delta2), absTolerance);
    }

    // @dev Asserts that `delta1` is approximately equal to `delta2` for both amount0 and amount1 with a custom error message
    function assertAproxEqAbs(BalanceDelta delta1, BalanceDelta delta2, uint256 absTolerance, string memory err)
        internal
    {
        assertApproxEqAbs(BalanceDeltaLibrary.amount1(delta1), BalanceDeltaLibrary.amount1(delta2), absTolerance, err);
        assertApproxEqAbs(BalanceDeltaLibrary.amount0(delta1), BalanceDeltaLibrary.amount0(delta2), absTolerance, err);
    }

    // @dev Asserts that `delta1` is not equal to `delta2` for both amount0 and amount1
    function assertNotEq(BalanceDelta delta1, BalanceDelta delta2) internal {
        bool amount0Different = BalanceDeltaLibrary.amount0(delta1) != BalanceDeltaLibrary.amount0(delta2);
        bool amount1Different = BalanceDeltaLibrary.amount1(delta1) != BalanceDeltaLibrary.amount1(delta2);
        assertTrue(amount0Different || amount1Different);
    }

    // @dev Asserts that `delta1` is not equal to `delta2` for both amount0 and amount1 with a custom error message
    function assertNotEq(BalanceDelta delta1, BalanceDelta delta2, string memory err) internal {
        bool amount0Different = BalanceDeltaLibrary.amount0(delta1) != BalanceDeltaLibrary.amount0(delta2);
        bool amount1Different = BalanceDeltaLibrary.amount1(delta1) != BalanceDeltaLibrary.amount1(delta2);
        assertTrue(amount0Different || amount1Different, err);
    }

    // @dev Asserts that delta1 is greater than delta2 for both amount0 and amount1
    function assertGt(BalanceDelta delta1, BalanceDelta delta2) internal {
        assertGt(BalanceDeltaLibrary.amount1(delta1), BalanceDeltaLibrary.amount1(delta2));
        assertGt(BalanceDeltaLibrary.amount0(delta1), BalanceDeltaLibrary.amount0(delta2));
    }

    // @dev Asserts that `delta1` is greater than `delta2` for both amount0 and amount1 with a custom error message
    function assertGt(BalanceDelta delta1, BalanceDelta delta2, string memory err) internal {
        assertGt(BalanceDeltaLibrary.amount1(delta1), BalanceDeltaLibrary.amount1(delta2), err);
        assertGt(BalanceDeltaLibrary.amount0(delta1), BalanceDeltaLibrary.amount0(delta2), err);
    }

    // @dev Asserts that delta1 is greater than delta2 for either amount0 or amount1
    function assertEitherGt(BalanceDelta delta1, BalanceDelta delta2) internal {
        bool amount1Gt = BalanceDeltaLibrary.amount1(delta1) > BalanceDeltaLibrary.amount1(delta2);
        bool amount0Gt = BalanceDeltaLibrary.amount0(delta1) > BalanceDeltaLibrary.amount0(delta2);
        assertTrue(amount1Gt || amount0Gt);
    }

    // @dev Asserts that delta1 is greater than delta2 for either amount0 or amount1 with a custom error message
    function assertEitherGt(BalanceDelta delta1, BalanceDelta delta2, string memory err) internal {
        bool amount1Gt = BalanceDeltaLibrary.amount1(delta1) > BalanceDeltaLibrary.amount1(delta2);
        bool amount0Gt = BalanceDeltaLibrary.amount0(delta1) > BalanceDeltaLibrary.amount0(delta2);
        assertTrue(amount1Gt || amount0Gt, err);
    }
}
