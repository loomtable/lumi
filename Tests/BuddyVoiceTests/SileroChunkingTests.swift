import Testing
@testable import BuddyVoice

struct SileroChunkingTests {
    @Test func regroupsIntoExactChunks() {
        var chunker = SampleChunker(size: 4096)
        #expect(chunker.push([Float](repeating: 0, count: 1600)).isEmpty)
        #expect(chunker.push([Float](repeating: 0, count: 1600)).isEmpty)
        let chunks = chunker.push([Float](repeating: 1, count: 6000))
        #expect(chunks.map(\.count) == [4096, 4096])
        #expect(chunks.count == 2)
        #expect(chunker.buffered == 1600 * 2 + 6000 - 8192)
    }

    @Test func keepsSampleOrder() {
        var chunker = SampleChunker(size: 4)
        let chunks = chunker.push((0..<10).map(Float.init))
        #expect(chunks == [[0, 1, 2, 3], [4, 5, 6, 7]])
        #expect(chunker.push([10, 11]) == [[8, 9, 10, 11]])
        chunker.reset()
        #expect(chunker.buffered == 0)
    }
}
