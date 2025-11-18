# Server Architecture

## Lifecycle

- **Start**: Explicitly run with `prise serve` command
- **Socket**: Creates Unix domain socket at `/tmp/prise-{uid}.sock`
- **Shutdown**: Server runs indefinitely until manually stopped (does not auto-exit)
- **Cleanup**: Removes stale socket on startup; cleans up socket on shutdown

## Threading Model

1. **Main Thread (Event Loop)**:
   - Accepts client connections and handles msgpack-RPC requests/responses/notifications
   - Manages PTY sessions and routes messages between clients and PTYs
   - Sends screen updates (redraw notifications) to attached clients
   - Writes to PTYs as needed (keyboard input, mouse events, resize)
   - Handles render timers and frame scheduling

2. **PTY Threads** (one per session):
   - Performs blocking reads from the underlying PTY file descriptor
   - Processes VT sequences using ghostty-vt, updating local terminal state
   - Handles automatic responses to VT queries (e.g. Device Attributes) by writing directly to PTY
   - Signals dirty state to main thread via pipe

## Event-Oriented Frame Scheduler

- **Per-PTY Pipe**: Each `Pty` owns a non-blocking pipe pair
  - Read end: Registered with main thread's event loop
  - Write end: Used by PTY thread to signal dirty state

- **Producer (PTY Thread)**:
  - After updating terminal state, writes a single byte to pipe
  - `EAGAIN` is ignored (signal already pending)

- **Consumer (Main Thread)**:
  - **On Pipe Read**: Drains the pipe. If enough time has passed since `last_render_time` (8ms), renders immediately. Otherwise, schedules a timer for the remaining duration.
  - **On Timer**: Renders frame and updates `last_render_time`

- **Cleanup**: Render timers are cancelled when PTY sessions are destroyed to prevent event loop from staying alive

# Client Architecture

1. **Main Thread (Event Loop)**:
   - Responsible for initializing the UI (raw mode, entering alternate screen) and
   establishing the connection to the Server.
   - Runs the `io.Loop`, listening to:
     - **Server Socket**: Reads messages from server (screen updates, events).
     - **Pipe**: Receives input and resize notifications from TTY Thread.
   - Updates the local screen state based on Server messages.
   - Paints the screen to the local terminal (`stdout`).
   - Parses input from the pipe and sends events to the Server Socket.

2. **TTY Thread (Input & Signal Handler)**:
   - **Loop**: Performs blocking reads on the local TTY (Input).
   - Forwards raw input to the Main Thread via pipe.
   - Handles `SIGWINCH` by serializing resize into in-band-resize notation
   and sending it through the pipe.

3. **Synchronization Flow**:
   - **Resize**: 
     1. TTY Thread detects `SIGWINCH` -> Serializes to in-band-resize -> Sends to pipe.
     2. Main Thread receives from pipe -> Sends resize request to Server.
     3. Server resizes internal PTY -> Sends resize event to Client.
     4. Main Thread receives event -> Updates renderer state -> Repaints.
   - **Shutdown**:
     - **User Quit**: TTY thread sends close request via pipe -> Main thread forwards to server -> Server closes connection -> Main thread detects close -> Exits process.
     - **Server Quit**: Main thread detects disconnect -> Exits process.

# Client Data Model

1. **Double Buffering**:
   - Each **Surface** maintains two `Screen` buffers:
     - **Front Buffer**: Represents the stable state for the current frame.
     - **Back Buffer**: Receives incremental updates from the server.
   - **Update Cycle**:
     1. **Receive**: Messages from the server update the **Back Buffer**.
     2. **Frame Boundary**: When a frame is ready, the Surface copies/swaps
        Back -> Front.
     3. **Render**: The application draws the **Front Buffer** into the Vaxis
        virtual screen.
     4. **Vaxis**: Handles the final diffing and generation of VT sequences to
        update the physical terminal.

2. **Surfaces**:

   - A **Surface** represents the state of a single remote PTY.
   - Each Surface owns its own pair of Front/Back buffers.
   - The Client manages a collection of Surfaces (one per connected PTY).
