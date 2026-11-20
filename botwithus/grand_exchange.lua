-- botwithus.grand_exchange -- the Grand Exchange slots (game:ge_offers()).
--
--   local offers = game:ge_offers()           -- nil, code on a refusal (not_available)
--   for _, o in ipairs(offers) do
--     if o.in_use then print(o.slot, o.type_name, o.item_id, o.sold_count, o.item_count) end
--   end
--
-- Market 0, all eight slots. Each row: slot, stage, stage_name, type, type_name, item_id,
-- item_count, sold_count, price (per item), gold_from_sale, plus in_use (stage ~= 0, the
-- agent's predicate) and is_sell. price and gold_from_sale can exceed 32 bits. An empty slot's
-- other fields are whatever the client left there.

local GrandExchange = {}

GrandExchange.SLOTS           = 8
GrandExchange.STAGE_EMPTY     = 0
GrandExchange.STAGE_ADDING    = 1
GrandExchange.STAGE_ADDED     = 2
GrandExchange.STAGE_VERIFYING = 3
GrandExchange.STAGE_ABORTING  = 4
GrandExchange.STAGE_FINISHED  = 5
GrandExchange.TYPE_BUY        = 0
GrandExchange.TYPE_SELL       = 1

-- The offers of a ge_offers reply, each with in_use and is_sell added.
function GrandExchange.decorate(reply)
  local offers = reply.offers
  for _, o in ipairs(offers) do
    o.in_use  = o.stage ~= GrandExchange.STAGE_EMPTY
    o.is_sell = o.type == GrandExchange.TYPE_SELL
  end
  return offers
end

-- The slots in use.
function GrandExchange.in_use(offers)
  local out = {}
  for _, o in ipairs(offers) do
    if o.in_use then out[#out + 1] = o end
  end
  return out
end

return GrandExchange
