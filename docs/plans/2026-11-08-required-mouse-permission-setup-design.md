# Required mouse-event permission at startup

The driver needs macOS permission to turn touch reports into mouse events. A
failed check currently exits with an error, causing launchd to restart the
process and repeat the request before the user can complete approval.

If access is already available, start normally. Otherwise, show a setup
window with Open System Settings, Check Again, and Quit. Explain why access is
required and keep touch processing and pairing off during setup. Ask macOS
for access when the user chooses Open System Settings. After the initial
request, that action opens Settings without issuing another prompt.
Check Again silently checks the installed process and starts the driver
only when macOS confirms access. Closing the window or choosing Quit exits
successfully so launchd leaves the driver stopped for that login session.
Other startup failures retain their existing exit behavior.

Verify the authorized and denied startup paths, the setup actions and
clean quit, and document how to restart the installed LaunchAgent.
