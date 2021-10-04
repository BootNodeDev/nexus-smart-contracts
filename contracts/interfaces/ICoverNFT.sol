

import "@openzeppelin/contracts-v4/token/ERC721/IERC721.sol";

interface ICoverNFT is IERC721 {

  function safeMint(address to, uint tokenId) external;

  function isApprovedOrOwner(address spender, uint tokenId) external returns (bool);

}
