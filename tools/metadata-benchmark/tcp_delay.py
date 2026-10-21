"""Bounded TCP delay for disposable tests. TLS bytes pass through unchanged.

Each received chunk has a delivery time. Delays can overlap; a large response
must not accumulate one artificial RTT for each chunk. This is a latency model,
not a bandwidth, packet-loss, or TCP congestion simulator.
"""
import asyncio
import threading
import time


class DelayProxy:
    def __init__(self, host, port, rtt_ms):
        if not 0 <= rtt_ms <= 1000:
            raise ValueError("RTT must be 0...1000 ms")
        self.host, self.port, self.delay = host, port, rtt_ms / 2000
        self.ready = threading.Event()
        self.error = None
        self.tasks = set()

    async def pipe(self, reader, writer):
        queue = asyncio.Queue(maxsize=64)

        async def read():
            while True:
                data = await reader.read(65536)
                await queue.put((time.monotonic() + self.delay, data))
                if not data:
                    return

        async def write():
            while True:
                due, data = await queue.get()
                await asyncio.sleep(max(0, due - time.monotonic()))
                if not data:
                    if writer.can_write_eof():
                        writer.write_eof()
                        await writer.drain()
                    return
                writer.write(data)
                await writer.drain()

        tasks = [asyncio.create_task(read()), asyncio.create_task(write())]
        try:
            await asyncio.gather(*tasks)
        finally:
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)

    async def accept(self, reader, writer):
        task = asyncio.current_task()
        if len(self.tasks) >= 32:
            writer.close()
            return
        self.tasks.add(task)
        upstream = None
        tasks = []
        try:
            incoming, upstream = await asyncio.open_connection(self.host, self.port)
            tasks = [asyncio.create_task(self.pipe(reader, upstream)),
                     asyncio.create_task(self.pipe(incoming, writer))]
            await asyncio.gather(*tasks)
        except (ConnectionError, OSError):
            pass
        finally:
            for item in tasks:
                item.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            writer.close()
            if upstream:
                upstream.close()
            self.tasks.discard(task)

    async def serve(self):
        self.loop = asyncio.get_running_loop()
        self.stop = asyncio.Event()
        async with await asyncio.start_server(self.accept, "127.0.0.1", 0) as server:
            self.listen_port = server.sockets[0].getsockname()[1]
            self.ready.set()
            await self.stop.wait()
        tasks = list(self.tasks)
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)

    def start(self):
        def worker():
            try:
                asyncio.run(self.serve())
            except BaseException as error:
                self.error = error
                self.ready.set()
        self.thread = threading.Thread(target=worker, daemon=True)
        self.thread.start()
        if not self.ready.wait(10):
            raise TimeoutError("proxy startup timed out")
        if self.error:
            raise self.error
        return self

    def close(self):
        if self.thread.is_alive():
            self.loop.call_soon_threadsafe(self.stop.set)
            self.thread.join(10)
        if self.thread.is_alive():
            raise TimeoutError("proxy shutdown timed out")
