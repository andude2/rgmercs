local mq = require('mq')
local actors = require('rgmercs.lib.actors')

-- Test mailbox registration
local test_handler = function(message)
    print("Received message in test mailbox:")
    local content = message()
    if type(content) == "table" then
        for k, v in pairs(content) do
            print(string.format("  %s: %s", k, tostring(v)))
        end
    else
        print("  Content: " .. tostring(content))
    end
end

-- Register a test mailbox
local mailbox_handle = actors.register("test_mailbox", test_handler)

if mailbox_handle then
    print("Successfully registered test mailbox")
    
    -- Send a test message to the mailbox
    print("Sending test message...")
    mailbox_handle:send({mailbox = "test_mailbox"}, {
        test_data = "Hello, World!",
        number = 42,
        boolean = true
    })
    
    -- Also try sending via the global send function
    print("Sending test message via global send...")
    actors.send({mailbox = "test_mailbox"}, {
        test_data = "Global send message",
        number = 24,
        boolean = false
    })
else
    print("Failed to register test mailbox")
end

print("Actors library test completed.")