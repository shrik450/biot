package resolve

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"strings"

	"github.com/shrik450/biot/cli/internal/api"
)

var canonicalUUID = regexp.MustCompile(`\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z`)

func Biot(ctx context.Context, client *api.Client, reference string) (api.Biot, error) {
	if canonicalUUID.MatchString(reference) {
		return client.GetBiot(ctx, reference)
	}
	biots, err := client.ListBiots(ctx)
	if err != nil {
		return api.Biot{}, err
	}
	matches := make([]api.Biot, 0, 1)
	for _, biot := range biots {
		if biot.Name == reference {
			matches = append(matches, biot)
		}
	}
	switch len(matches) {
	case 1:
		return matches[0], nil
	case 0:
		return api.Biot{}, errors.New("That Biot was not found.")
	default:
		ids := make([]string, len(matches))
		for index, match := range matches {
			ids[index] = match.ID
		}
		return api.Biot{}, fmt.Errorf("Biot name %q is ambiguous; matching IDs are %s. Use an ID.", reference, strings.Join(ids, ", "))
	}
}
