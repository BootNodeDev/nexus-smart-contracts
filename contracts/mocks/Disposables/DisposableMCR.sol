pragma solidity ^0.5.0;

import "../../modules/capital/MCR.sol";

contract DisposableMCR is MCR {

    function initialize(
        address master,
        uint _mcr,
        uint _mcrFloor,
        uint _lastUpdateTime,
        uint _mcrFloorIncrementThreshold,
        uint _maxMCRFloorIncrement,
        uint _maxMCRIncrement,
        uint _gearingFactor
    ) external {
        require(_lastUpdateTime < now, "_lastUpdateTime is in the future");
        changeMasterAddress(master);
        mcr = _mcr;
        mcrFloor = _mcrFloor;
        lastUpdateTime = _lastUpdateTime;
        mcrFloorIncrementThreshold = _mcrFloorIncrementThreshold;
        maxMCRFloorIncrement = _maxMCRFloorIncrement;
        maxMCRIncrement = _maxMCRIncrement;
        gearingFactor = _gearingFactor;
    }
}
