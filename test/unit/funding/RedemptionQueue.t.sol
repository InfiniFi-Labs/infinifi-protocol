pragma solidity 0.8.28;

import {Test} from "@forge-std/Test.sol";
import {RedemptionQueue} from "@libraries/RedemptionQueue.sol";

contract RedemptionQueueTest is Test {
    using RedemptionQueue for RedemptionQueue.RedemptionRequestsQueue;

    RedemptionQueue.RedemptionRequestsQueue public queue;

    function testSetUp() public view {
        assertEq(queue.length(), 0, "Queue should be empty");
    }

    /// @notice test the pushBack function
    /// the pushBack function is used to add a redemption request to the queue
    function testPushBack() public {
        queue.pushBack(RedemptionQueue.RedemptionRequest({recipient: makeAddr("RECIPIENT"), amount: 1e18}));
        assertEq(queue.length(), 1, "Error: Queue should have 1 element");
        assertEq(queue.front().recipient, makeAddr("RECIPIENT"), "Error: Recipient should be the one we pushed");
        assertEq(queue.front().amount, 1e18, "Error: Amount should be the one we pushed");
    }

    /// @notice test the pushBack function with two elements
    /// the pushBack function should add the request to the end of the queue so recipient_2 should be at index 1
    function testPushBackTwice() public {
        queue.pushBack(RedemptionQueue.RedemptionRequest({recipient: makeAddr("RECIPIENT_1"), amount: 1e18}));
        queue.pushBack(RedemptionQueue.RedemptionRequest({recipient: makeAddr("RECIPIENT_2"), amount: 2e18}));
        assertEq(queue.length(), 2, "Error: Queue should have 2 elements");
        assertEq(
            queue.front().recipient, makeAddr("RECIPIENT_1"), "Error: First recipient should be the first one we pushed"
        );
        assertEq(queue.front().amount, 1e18, "Error: First amount should be the first one we pushed");
        assertEq(
            queue.at(1).recipient, makeAddr("RECIPIENT_2"), "Error: Second recipient should be the second one we pushed"
        );
        assertEq(queue.at(1).amount, 2e18, "Error: Second amount should be the second one we pushed");
    }

    /// @notice test the queue length
    /// the queue length should be the number of elements in the queue, fuzzing just for the sake of it
    function testQueueLength(uint256 _targetLength) public {
        _targetLength = bound(_targetLength, 0, 100); // don't push too many requests otherwise testing takes too long
        assertEq(queue.length(), 0, "Queue should be empty");
        for (uint256 i = 0; i < _targetLength; i++) {
            queue.pushBack(
                RedemptionQueue.RedemptionRequest({
                    recipient: makeAddr(string.concat("RECIPIENT_", vm.toString(i))), amount: 1e18
                })
            );
        }
        assertEq(queue.length(), _targetLength, "Error: Queue should have the target length");
    }

    /// @notice test the popFront function
    /// the popFront function should remove the first element of the queue
    /// when empty, it should revert with QueueIsEmpty() error
    /// forge-config: default.allow_internal_expect_revert = true
    function testPopFrontRevertsWhenEmpty() public {
        vm.expectRevert(abi.encodeWithSelector(RedemptionQueue.QueueIsEmpty.selector));
        queue.popFront();
    }

    /// @notice test the front function
    /// the front function should return the first element of the queue
    /// when empty, it should revert with QueueIsEmpty() error
    /// forge-config: default.allow_internal_expect_revert = true
    function testFrontRevertsWhenEmpty() public {
        vm.expectRevert(abi.encodeWithSelector(RedemptionQueue.QueueIsEmpty.selector));
        queue.front();
    }

    /// @notice test the popFront function
    /// the popFront function should remove the first element of the queue
    /// and return it so the queue should be empty after if it only has one element
    function testPopFront() public {
        queue.pushBack(RedemptionQueue.RedemptionRequest({recipient: makeAddr("RECIPIENT_1"), amount: 1e18}));
        RedemptionQueue.RedemptionRequest memory request = queue.popFront();
        assertEq(queue.length(), 0, "Error: Queue should be empty");
        assertEq(request.recipient, makeAddr("RECIPIENT_1"), "Error: Recipient should be the one we pushed");
        assertEq(request.amount, 1e18, "Error: Amount should be the one we pushed");
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testUpdateFrontShouldRevertWhenQueueIsEmpty() public {
        vm.expectRevert(abi.encodeWithSelector(RedemptionQueue.QueueIsEmpty.selector));
        queue.updateFront(2e18);
    }

    /// @notice test the updateFront function
    /// the updateFront function should update the amount of the first element of the queue
    /// this function is necessary for partial redemption funding and can only be called for the first element
    function testUpdateFront() public {
        queue.pushBack(RedemptionQueue.RedemptionRequest({recipient: makeAddr("RECIPIENT_1"), amount: 1e18}));
        queue.updateFront(2e18);
        assertEq(queue.front().amount, 2e18, "Amount should be updated");
    }

    /// @notice test the at function
    /// the at function should return the element at the given index
    /// when the index is out of bounds, it should revert with IndexOutOfBounds() error
    /// forge-config: default.allow_internal_expect_revert = true
    function testAtRevertsWhenIndexOutOfBounds() public {
        queue.pushBack(RedemptionQueue.RedemptionRequest({recipient: makeAddr("RECIPIENT_1"), amount: 1e18}));
        vm.expectRevert(abi.encodeWithSelector(RedemptionQueue.IndexOutOfBounds.selector, 1));
        queue.at(1);
    }

    /// @notice test the at function
    /// the at function should return the element at the given index
    function testAt() public {
        queue.pushBack(RedemptionQueue.RedemptionRequest({recipient: makeAddr("RECIPIENT_1"), amount: 1e18}));
        queue.pushBack(RedemptionQueue.RedemptionRequest({recipient: makeAddr("RECIPIENT_2"), amount: 2e18}));
        queue.pushBack(RedemptionQueue.RedemptionRequest({recipient: makeAddr("RECIPIENT_3"), amount: 3e18}));
        assertEq(queue.at(1).recipient, makeAddr("RECIPIENT_2"), "Error: Recipient should be the second one we pushed");
        assertEq(queue.at(1).amount, 2e18, "Error: Amount should be the second one we pushed");
    }

    /// @notice test the pushBack function
    /// the pushBack function should revert when the queue is full
    /// to do that we "fake" the _end value to be uint128.max while _begin is 0, meaning the next pushBack will overflow the value
    /// but because it's in an unchecked block, it will not revert, it will just set the _end to 0, reverting with the correct error
    /// forge-config: default.allow_internal_expect_revert = true
    function testPushBackQueueIsFull() public {
        queue._begin = 0;
        queue._end = type(uint128).max;
        vm.expectRevert(abi.encodeWithSelector(RedemptionQueue.QueueIsFull.selector));
        queue.pushBack(RedemptionQueue.RedemptionRequest({recipient: makeAddr("RECIPIENT"), amount: 1e18}));
    }

    function testFuzzQueueAcrossIndexWraparound(uint96[4] memory amounts, address[4] memory recipients) public {
        queue._begin = type(uint128).max - 1;
        queue._end = queue._begin;

        for (uint256 i = 0; i < amounts.length; i++) {
            queue.pushBack(RedemptionQueue.RedemptionRequest({recipient: recipients[i], amount: amounts[i]}));
            assertEq(queue.length(), i + 1);
        }
        assertEq(queue._end, 2);
        for (uint256 i = 0; i < amounts.length; i++) {
            assertEq(queue.at(i).amount, amounts[i]);
            assertEq(queue.at(i).recipient, recipients[i]);
        }

        for (uint256 i = 0; i < amounts.length; i++) {
            assertEq(queue.front().amount, amounts[i]);
            assertEq(queue.front().recipient, recipients[i]);
            RedemptionQueue.RedemptionRequest memory request = queue.popFront();
            assertEq(request.amount, amounts[i]);
            assertEq(request.recipient, recipients[i]);
            assertEq(queue.length(), amounts.length - i - 1);
        }
        assertTrue(queue.empty());
        assertEq(queue._begin, queue._end);
    }

    function testFuzzUpdateFrontPreservesRecipientAndTail(uint96 amount, uint96 newAmount, address recipient) public {
        queue.pushBack(RedemptionQueue.RedemptionRequest({recipient: recipient, amount: amount}));
        queue.pushBack(RedemptionQueue.RedemptionRequest({recipient: makeAddr("TAIL"), amount: type(uint96).max}));

        queue.updateFront(newAmount);

        assertEq(queue.length(), 2);
        assertEq(queue.front().amount, newAmount);
        assertEq(queue.front().recipient, recipient);
        assertEq(queue.at(1).amount, type(uint96).max);
        assertEq(queue.at(1).recipient, makeAddr("TAIL"));
        assertEq(queue.popFront().amount, newAmount);
        assertEq(queue.front().amount, type(uint96).max);
    }

    function testFuzzDrainedQueueCanReuseWrappedIndices(uint96 amount, address recipient) public {
        queue._begin = type(uint128).max;
        queue._end = type(uint128).max;
        queue.pushBack(RedemptionQueue.RedemptionRequest({recipient: makeAddr("OLD"), amount: 1e18}));
        queue.popFront();
        assertTrue(queue.empty());
        assertEq(queue._begin, 0);
        assertEq(queue._end, 0);

        queue.pushBack(RedemptionQueue.RedemptionRequest({recipient: recipient, amount: amount}));
        assertEq(queue.length(), 1);
        assertEq(queue.front().amount, amount);
        assertEq(queue.front().recipient, recipient);
        queue.popFront();
        assertTrue(queue.empty());
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testAtUsesRelativeIndexAfterPop() public {
        queue.pushBack(RedemptionQueue.RedemptionRequest({recipient: makeAddr("FIRST"), amount: 1e18}));
        queue.pushBack(RedemptionQueue.RedemptionRequest({recipient: makeAddr("SECOND"), amount: 2e18}));
        queue.popFront();

        assertEq(queue.at(0).recipient, makeAddr("SECOND"));
        assertEq(queue.at(0).amount, 2e18);
        vm.expectRevert(abi.encodeWithSelector(RedemptionQueue.IndexOutOfBounds.selector, 1));
        queue.at(1);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testAtRejectsMaximumIndex() public {
        queue.pushBack(RedemptionQueue.RedemptionRequest({recipient: makeAddr("RECIPIENT"), amount: 1e18}));
        vm.expectRevert(abi.encodeWithSelector(RedemptionQueue.IndexOutOfBounds.selector, type(uint256).max));
        queue.at(type(uint256).max);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testFullQueueRevertsAcrossWrappedIndices() public {
        queue._begin = 7;
        queue._end = 6;
        vm.expectRevert(abi.encodeWithSelector(RedemptionQueue.QueueIsFull.selector));
        queue.pushBack(RedemptionQueue.RedemptionRequest({recipient: makeAddr("RECIPIENT"), amount: 1e18}));
    }
}
