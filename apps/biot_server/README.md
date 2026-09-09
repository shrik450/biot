# Biot Server

Biot Server owns the server application modules, queries, policy, and server database. It owns authorization, durable intent, observations, and operation meaning.

After you change the node enrollment file, run `bin/server rpc "Biot.Server.Nodes.reload()"`. Use `rpc` so the running server can close control connections whose registrations changed.
