/*
Copyright 2026 The llm-d Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package kvblock_test

import (
	"fmt"
	"testing"

	"github.com/llm-d/llm-d-router/pkg/kvcache/kvblock"
)

// benchTokens returns n synthetic token IDs.
func benchTokens(n int) []uint32 {
	tokens := make([]uint32, n)
	for i := range tokens {
		tokens[i] = uint32(i%50000 + 1)
	}
	return tokens
}

// BenchmarkTokensToKVBlockKeys measures block-key derivation for a 240K-token
// prompt at production (64) and default (16) block sizes.
func BenchmarkTokensToKVBlockKeys(b *testing.B) {
	for _, bs := range []int{16, 64} {
		b.Run(fmt.Sprintf("tokens=240K/blockSize=%d", bs), func(b *testing.B) {
			tp, err := kvblock.NewChunkedTokenDatabase(&kvblock.TokenProcessorConfig{BlockSizeTokens: bs})
			if err != nil {
				b.Fatal(err)
			}
			tokens := benchTokens(240_000)
			b.ReportAllocs()
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				keys, err := tp.TokensToKVBlockKeys(kvblock.EmptyBlockHash, tokens, "bench-model", nil)
				if err != nil {
					b.Fatal(err)
				}
				if len(keys) != 240_000/bs {
					b.Fatalf("unexpected key count %d", len(keys))
				}
			}
		})
	}
}
