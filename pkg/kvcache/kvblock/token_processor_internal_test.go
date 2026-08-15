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

package kvblock

import (
	"hash/fnv"
	"math/rand"
	"testing"

	"github.com/fxamacker/cbor/v2"
	"github.com/stretchr/testify/require"
)

// encoderDigest is the reference implementation: FNV-64a over the canonical
// CBOR encoding of [parent, tokens, nil].
func encoderDigest(t *testing.T, encoder cbor.EncMode, parent uint64, tokens []uint32) uint64 {
	t.Helper()
	b, err := encoder.Marshal([]interface{}{parent, tokens, nil})
	require.NoError(t, err)
	h := fnv.New64a()
	_, _ = h.Write(b)
	return h.Sum64()
}

// TestHashTextOnlyMatchesEncoder pins hashTextOnly to the encoder path it
// replaces: both must produce identical digests for every input, or block
// identities diverge from vLLM's prefix-cache hashes.
func TestHashTextOnlyMatchesEncoder(t *testing.T) {
	encoder, err := cbor.CanonicalEncOptions().EncMode()
	require.NoError(t, err)

	// Parents and token values crossing every canonical CBOR head width.
	widthEdges := []uint64{0, 1, 23, 24, 0xff, 0x100, 0xffff, 0x10000, 0xffffffff, 0x100000000, 0xffffffffffffffff}
	tokenEdges := []uint32{0, 1, 23, 24, 0xff, 0x100, 0xffff, 0x10000, 0xffffffff}

	for _, parent := range widthEdges {
		for _, tok := range tokenEdges {
			tokens := []uint32{tok}
			require.Equal(t, encoderDigest(t, encoder, parent, tokens), hashTextOnly(parent, tokens),
				"digest mismatch for parent=%d token=%d", parent, tok)
		}
	}

	// Token-count edges crossing the array head widths.
	for _, n := range []int{1, 16, 23, 24, 64, 255, 256, 4096} {
		tokens := make([]uint32, n)
		for i := range tokens {
			tokens[i] = uint32(i * 7919)
		}
		for _, parent := range []uint64{0, 0xdeadbeefcafe} {
			require.Equal(t, encoderDigest(t, encoder, parent, tokens), hashTextOnly(parent, tokens),
				"digest mismatch for parent=%d len(tokens)=%d", parent, n)
		}
	}

	// Randomized sweep.
	rng := rand.New(rand.NewSource(1))
	for i := 0; i < 1000; i++ {
		tokens := make([]uint32, 1+rng.Intn(128))
		for j := range tokens {
			tokens[j] = rng.Uint32()
		}
		parent := rng.Uint64()
		require.Equal(t, encoderDigest(t, encoder, parent, tokens), hashTextOnly(parent, tokens),
			"digest mismatch for random case %d", i)
	}
}
