package main

import (
	"strings"
	"testing"

	"github.com/shrik450/biot/cli/internal/api"
)

// TestListRowIsATable proves a marked row keeps the header's column count: the SECRETS column holds
// a word, not the sentence `show` prints.
func TestListRowIsATable(t *testing.T) {
	headerColumns := len(strings.Split(listHeader, "\t"))

	tests := []struct {
		name   string
		marked bool
		want   string
	}{
		{name: "marked", marked: true, want: secretExposureMarker},
		{name: "unmarked", marked: false, want: ""},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			row := listRow(api.Biot{
				Name:                         "demo",
				ID:                           "00000000-0000-4000-8000-000000000001",
				Desired:                      api.Desired{State: "running"},
				Node:                         "node",
				DirectSecretExposurePossible: test.marked,
			})

			fields := strings.Split(row, "\t")
			if len(fields) != headerColumns {
				t.Fatalf("row has %d columns, header has %d: %q", len(fields), headerColumns, row)
			}
			if got := fields[headerColumns-1]; got != test.want {
				t.Fatalf("SECRETS column = %q, want %q", got, test.want)
			}
			if strings.Contains(row, secretExposureWarning) {
				t.Fatalf("the row used the full sentence: %q", row)
			}
		})
	}
}
