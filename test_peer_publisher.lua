local mq = require('mq')
local PeerPublisher = require('rgmercs.utils.peer_publisher')

-- Initialize the peer publisher
PeerPublisher.init()

-- Main loop for testing
local function main()
    print("Starting peer publisher test...")
    
    local count = 0
    while count < 100 do  -- Run for 100 iterations
        -- Update the peer publisher
        PeerPublisher.update()
        
        -- Print a message every 10 iterations
        if count % 10 == 0 then
            print(string.format("Peer publisher update #%d", count))
        end
        
        count = count + 1
        mq.delay(100)  -- Delay for 100ms
    end
    
    print("Peer publisher test completed.")
end

main()