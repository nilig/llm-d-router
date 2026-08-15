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

package preciseprefixcache

import (
	"context"
	"fmt"

	"github.com/go-logr/logr"
	"k8s.io/apimachinery/pkg/labels"
	"sigs.k8s.io/controller-runtime/pkg/log"

	"github.com/llm-d/llm-d-router/pkg/common/observability/logging"
	fwkdl "github.com/llm-d/llm-d-router/pkg/epp/framework/interface/datalayer"
)

var _ fwkdl.EndpointExtractor = &Producer{}

// Extract processes endpoint lifecycle events emitted by the
// endpoint-notification-source: add/update installs a per-pod ZMQ KV-events
// subscriber, delete tears one down. No-op unless per-pod discovery is
// enabled.
func (p *Producer) Extract(ctx context.Context, event fwkdl.EndpointEvent) error {
	if !p.kvEventsConfig.DiscoverPods || p.kvEventsConfig.PodDiscoveryConfig == nil {
		return nil
	}
	meta := event.Endpoint.GetMetadata()
	if meta == nil || meta.ID.Name == "" {
		return nil
	}

	logger := log.FromContext(ctx).WithName(p.typedName.String())
	endpointKey := meta.ID.String()

	switch event.Type {
	case fwkdl.EventAddOrUpdate:
		// PodLabelSelector narrows which endpoints get subscribers (e.g.
		// prefill ranks only); a nil selector filters nothing. A subscribed
		// endpoint whose pod stops matching after a relabel is torn down like
		// a deleted one - subscriber and learned index entries both - so no
		// stale locality data survives the transition. Never-subscribed
		// non-matching endpoints are skipped without touching the index.
		if p.podSelector != nil && !p.podSelector.Matches(labels.Set(meta.Labels)) {
			// RemoveSubscriberAndReset keys the reset by the subscriber's
			// stored source endpoint (the event's metadata may already carry
			// a new address) and orders it behind that source's queued
			// events, clearing index and deduplication state together.
			if prev := p.subscribersManager.RemoveSubscriberAndReset(ctx, endpointKey); prev != "" {
				logger.V(logging.DEBUG).Info("Removed KV-events subscriber", "endpoint", endpointKey)
			}
			logger.V(logging.DEBUG).Info("Endpoint does not match podLabelSelector, skipping subscriber",
				"endpoint", endpointKey)
			return nil
		}
		if err := p.ensureSubscriber(ctx, meta); err != nil {
			return err
		}
		logger.V(logging.DEBUG).Info("Adding subscriber", "endpoint", endpointKey)
	case fwkdl.EventDelete:
		prev := p.subscribersManager.RemoveSubscriberAndReset(ctx, endpointKey)
		// Also clear under the endpoint's current identity: speculative
		// entries are keyed by it, and it differs from the subscriber's
		// stored source endpoint after an address change. These entries are
		// not event-sourced, so a direct clear needs no queue ordering.
		if current := servingEndpoint(meta); current != "" && current != prev {
			p.clearIndexFor(ctx, logger, endpointKey, current)
		}
		logger.V(logging.DEBUG).Info("Removed KV-events subscriber", "endpoint", endpointKey)
	}
	return nil
}

// servingEndpoint returns the endpoint's Address:Port identity, or "" when
// the metadata carries no address.
func servingEndpoint(meta *fwkdl.EndpointMetadata) string {
	if meta.Address == "" {
		return ""
	}
	return fmt.Sprintf("%s:%s", meta.Address, meta.Port)
}

// clearIndexFor removes the index entries attributed to podIdentifier.
func (p *Producer) clearIndexFor(ctx context.Context, logger logr.Logger, endpointKey, podIdentifier string) {
	if err := p.kvCacheIndexer.KVBlockIndex().Clear(ctx, podIdentifier); err != nil {
		logger.Error(err, "Failed to clear index entries for removed endpoint",
			"endpoint", endpointKey, "podIdentifier", podIdentifier)
	}
}

// ensureSubscriber idempotently installs a KV-events subscriber for the given
// endpoint, dialing SocketPort + RankIndex to match standard inference-engine port offsetting
// (one ZMQ PUB socket per DP rank on the same pod IP).
func (p *Producer) ensureSubscriber(ctx context.Context, meta *fwkdl.EndpointMetadata) error {
	if meta == nil || meta.Address == "" {
		return nil
	}
	endpointKey := meta.ID.String()
	port := p.kvEventsConfig.PodDiscoveryConfig.SocketPort + meta.GetRankIndex()
	zmqEndpoint := fmt.Sprintf("tcp://%s:%d", meta.Address, port)
	replayEndpoint := ""
	if replayPort := p.kvEventsConfig.PodDiscoveryConfig.EffectiveReplayPort(); replayPort > 0 {
		replayEndpoint = fmt.Sprintf("tcp://%s:%d", meta.Address, replayPort+meta.GetRankIndex())
	}
	sourceEndpoint := fmt.Sprintf("%s:%s", meta.Address, meta.Port)

	logger := log.FromContext(ctx).WithName(p.typedName.String())
	// subscriberCtx is plugin-lifetime; caller ctx would tear subscribers
	// down on request completion.
	if err := p.subscribersManager.EnsureSubscriber(p.subscriberCtx, endpointKey,
		sourceEndpoint, zmqEndpoint, replayEndpoint, p.kvEventsConfig.TopicFilter, true); err != nil {
		logger.Error(err, "Failed to ensure KV-events subscriber for endpoint",
			"endpoint", endpointKey, "address", meta.Address)
		return fmt.Errorf("ensure subscriber for %s: %w", endpointKey, err)
	}
	logger.V(logging.DEBUG).Info("Ensured KV-events subscriber",
		"endpoint", endpointKey, "zmq", zmqEndpoint, "replay", replayEndpoint)
	return nil
}
