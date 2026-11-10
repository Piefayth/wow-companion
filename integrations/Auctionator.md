# Auctionator

Auction prices from the player's own scans.

Prices from the player's auction house scans, via
`Auctionator.API.v1` (callerID is a string naming you, e.g. 'WowCompanion'):
`GetAuctionPriceByItemID(callerID, itemID)`, `GetVendorPriceByItemID`,
`GetAuctionAgeByItemID` (days since seen). Nil means never scanned: ask them to
open the auction house once. Source: AddOns/Auctionator/Source/API.
