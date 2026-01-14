// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract Pausable {
    bool private _paused;

    event Paused(address account);
    event Unpaused(address account);

    modifier whenNotPaused() {
        require(!_paused, "Pausable: paused");
        _;
    }

    function paused() public view returns (bool) {
        return _paused;
    }

    function _pause() internal {
        if (!_paused) {
            _paused = true;
            emit Paused(msg.sender);
        }
    }

    function _unpause() internal {
        if (_paused) {
            _paused = false;
            emit Unpaused(msg.sender);
        }
    }
}
