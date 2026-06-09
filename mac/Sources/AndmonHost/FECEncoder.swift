import Foundation

final class FECEncoder: @unchecked Sendable {
    func encode(dataChunks: [Data], groupSize: Int) -> [Data] {
        guard groupSize > 0, !dataChunks.isEmpty else { return dataChunks }
        
        var chunks = dataChunks
        let numData = dataChunks.count
        let numParity = (numData + groupSize - 1) / groupSize
        
        // Generate the parity chunks
        var parityChunks: [Data] = []
        
        for g in 0..<numParity {
            let start = g * groupSize
            let end = min(start + groupSize, numData)
            
            // Find the maximum size among the data chunks in this group
            var maxSize = 0
            for i in start..<end {
                maxSize = max(maxSize, chunks[i].count)
            }
            
            // Each virtual buffer consists of: [2B length] + payload
            let virtualSize = 2 + maxSize
            var parityPayload = Data(repeating: 0, count: virtualSize)
            
            for i in start..<end {
                let chunk = chunks[i]
                let len = UInt16(chunk.count)
                var bigLen = len.bigEndian
                
                // XOR length bytes
                withUnsafeBytes(of: &bigLen) { lenBytes in
                    parityPayload[0] ^= lenBytes[0]
                    parityPayload[1] ^= lenBytes[1]
                }
                
                // XOR payload bytes
                for j in 0..<chunk.count {
                    parityPayload[2 + j] ^= chunk[j]
                }
            }
            
            parityChunks.append(parityPayload)
        }
        
        // Append parity chunks at the end of the chunks array
        chunks.append(contentsOf: parityChunks)
        return chunks
    }
}
