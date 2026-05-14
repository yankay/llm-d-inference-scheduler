/*
Copyright 2026 The Kubernetes Authors.

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

package approximateprefix

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"os"
	"sync/atomic"
	"time"

	"github.com/cespare/xxhash/v2"
	"sigs.k8s.io/controller-runtime/pkg/log"

	logutil "github.com/llm-d/llm-d-inference-scheduler/pkg/common/observability/logging"
	"github.com/llm-d/llm-d-inference-scheduler/pkg/epp/framework/interface/scheduling"
)

var (
	prefixHashTimingDebugEnabled = os.Getenv("EPP_TIMING_DEBUG") != ""

	prefixHashTimingCount         atomic.Uint64
	prefixHashTimingTotalNS       atomic.Int64
	prefixHashTimingGetInputNS    atomic.Int64
	prefixHashTimingHashLoopNS    atomic.Int64
	prefixHashTimingInputBytes    atomic.Uint64
	prefixHashTimingGeneratedHash atomic.Uint64
)

// hashPrompt divides the prompt into blocks and calculates a prefix cache hash for each block.
// The first block hash includes the model name and cache salt (if provided).
// For subsequent blocks, the hash is calculated as: hash(block i content, hash(i-1)).
func hashPrompt(ctx context.Context, request *scheduling.InferenceRequest, blockSizeTokens int, maxPrefixBlocks int) []blockHash {
	totalStart := time.Now()
	loggerDebug := log.FromContext(ctx).V(logutil.DEBUG)
	if request == nil || request.Body == nil {
		loggerDebug.Info("Request or request data is nil, skipping hashing")
		return nil
	}

	getInputStart := time.Now()
	userInput, err := getUserInputBytes(request)
	getInputDuration := time.Since(getInputStart)
	if err != nil {
		loggerDebug.Error(err, "Failed to get user input bytes")
		return nil
	}

	// convert block size from tokens to characters
	cacheBlockSizeChars := blockSizeTokens * averageCharactersPerToken

	if cacheBlockSizeChars <= 0 {
		loggerDebug.Info("Skipping prefix hashing: block size in characters must be positive",
			"blockSizeTokens", blockSizeTokens,
			"cacheBlockSizeChars", cacheBlockSizeChars)
		return nil
	}

	if len(userInput) < cacheBlockSizeChars {
		loggerDebug.Info("Request body too small for prefix cache", "size", len(userInput), "block size in chars", cacheBlockSizeChars)
		return nil
	}

	if len(userInput) > cacheBlockSizeChars*maxPrefixBlocks {
		loggerDebug.Info("Truncating input", "size", len(userInput), "max prefix blocks", maxPrefixBlocks, "block size in chars", cacheBlockSizeChars)
		userInput = userInput[:maxPrefixBlocks*cacheBlockSizeChars]
	}

	// Split the body into blocks of size cacheBlockSizeChars.
	res := make([]blockHash, 0, len(userInput)/cacheBlockSizeChars)

	hashLoopStart := time.Now()
	h := xxhash.New()
	// Different models should have different hashes even with the same body.
	_, _ = h.Write([]byte(request.TargetModel))
	if cacheSalt := request.Body.CacheSalt(); cacheSalt != "" {
		_, _ = h.Write([]byte(cacheSalt))
	}

	prevBlockHash := blockHash(h.Sum64())
	i := 0
	for ; i+cacheBlockSizeChars <= len(userInput); i += cacheBlockSizeChars {
		h.Reset()
		_, _ = h.Write(userInput[i : i+cacheBlockSizeChars])
		_, _ = h.Write(toBytes(prevBlockHash))
		res = append(res, blockHash(h.Sum64()))

		prevBlockHash = res[len(res)-1]
	}

	// 2. Process any remaining bytes as a partial block
	if i < len(userInput) {
		h.Reset()

		_, _ = h.Write(userInput[i:])
		_, _ = h.Write(toBytes(prevBlockHash))
		res = append(res, blockHash(h.Sum64()))
	}
	if prefixHashTimingDebugEnabled {
		recordPrefixHashTiming(ctx, time.Since(totalStart), getInputDuration, time.Since(hashLoopStart), len(userInput), len(res))
	}

	return res
}

func toBytes(i blockHash) []byte {
	bytes := make([]byte, 8)
	binary.LittleEndian.PutUint64(bytes, uint64(i))
	return bytes
}

func recordPrefixHashTiming(ctx context.Context, total, getInput, hashLoop time.Duration, inputBytes int, generatedHashes int) {
	n := prefixHashTimingCount.Add(1)
	prefixHashTimingTotalNS.Add(total.Nanoseconds())
	prefixHashTimingGetInputNS.Add(getInput.Nanoseconds())
	prefixHashTimingHashLoopNS.Add(hashLoop.Nanoseconds())
	prefixHashTimingInputBytes.Add(uint64(inputBytes))
	prefixHashTimingGeneratedHash.Add(uint64(generatedHashes))
	if n%100 != 0 {
		return
	}
	count := float64(n)
	log.FromContext(ctx).Info("Approx prefix hash timing aggregate",
		"requests", n,
		"avgTotalMs", float64(prefixHashTimingTotalNS.Load())/count/float64(time.Millisecond),
		"avgGetInputMs", float64(prefixHashTimingGetInputNS.Load())/count/float64(time.Millisecond),
		"avgHashLoopMs", float64(prefixHashTimingHashLoopNS.Load())/count/float64(time.Millisecond),
		"avgInputBytes", float64(prefixHashTimingInputBytes.Load())/count,
		"avgGeneratedHashes", float64(prefixHashTimingGeneratedHash.Load())/count,
	)
}

func getUserInputBytes(request *scheduling.InferenceRequest) ([]byte, error) {
	switch {
	case request.Body.Conversations != nil:
		return json.Marshal(request.Body.Conversations.Items)

	case request.Body.Responses != nil:
		var combined []map[string]interface{}
		if request.Body.Responses.Instructions != nil {
			combined = append(combined, map[string]interface{}{"instructions": request.Body.Responses.Instructions})
		}
		if request.Body.Responses.Tools != nil {
			combined = append(combined, map[string]interface{}{"tools": request.Body.Responses.Tools})
		}
		combined = append(combined, map[string]interface{}{"input": request.Body.Responses.Input})
		return json.Marshal(combined)

	case request.Body.ChatCompletions != nil:
		return json.Marshal(request.Body.ChatCompletions.Messages)

	case request.Body.Completions != nil:
		return []byte(request.Body.Completions.Prompt.PlainText()), nil

	case request.Body.Embeddings != nil:
		// Handle embeddings API - marshal input for cache key generation
		return json.Marshal(request.Body.Embeddings.Input)

	default:
		return nil, errors.New("invalid request body: no recognized API format found")
	}
}
