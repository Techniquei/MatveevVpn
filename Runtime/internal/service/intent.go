package service

import (
	"context"
	"errors"
	"os"

	"matveevvpn/runtime/internal/lists"
)

// ApplyIntent expands pinned lists owned by the service, then uses the normal commit path.
// The caller cannot choose the rules file or the generated Xray configuration.
func (s *Service) ApplyIntent(ctx context.Context, id string, expected uint64, intent lists.Intent) (Status, error) {
	if intent.AdBlocking {
		if s.options.RulesFile == "" {
			return s.Status(), errors.New("invalid_snapshot")
		}
		data, err := os.ReadFile(s.options.RulesFile)
		if err != nil {
			return s.Status(), errors.New("invalid_snapshot")
		}
		domains, err := lists.ImportHaGeZi(data)
		if err != nil {
			return s.Status(), errors.New("invalid_snapshot")
		}
		intent.BlockDomains = domains
	}
	compiled, err := lists.Compile(intent)
	if err != nil {
		return s.Status(), errors.New("invalid_snapshot")
	}
	return s.Apply(ctx, id, expected, compiled.Snapshot)
}
