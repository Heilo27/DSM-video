package metadata

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

// Fixtures below follow the shape of real TMDb responses
// (/movie/{id}?append_to_response=release_dates and /tv/{id}?append_to_response=content_ratings).

func rd(country string, releases ...ReleaseDate) ReleaseDatesCountry {
	return ReleaseDatesCountry{ISO3166_1: country, ReleaseDates: releases}
}

func TestUSMovieCertification(t *testing.T) {
	cases := []struct {
		name string
		in   *ReleaseDates
		want string
	}{
		{"nil block", nil, ""},
		{"no results at all", &ReleaseDates{}, ""},
		{"no US entry", &ReleaseDates{Results: []ReleaseDatesCountry{
			rd("GB", ReleaseDate{Certification: "12A", Type: 3}),
			rd("DE", ReleaseDate{Certification: "6", Type: 3}),
		}}, ""},
		{"US entry but every certification empty", &ReleaseDates{Results: []ReleaseDatesCountry{
			rd("US", ReleaseDate{Certification: "", Type: 3}, ReleaseDate{Certification: "  ", Type: 4}),
		}}, ""},
		{"single US theatrical", &ReleaseDates{Results: []ReleaseDatesCountry{
			rd("US", ReleaseDate{Certification: "PG-13", Type: 3}),
		}}, "PG-13"},
		{"other countries are ignored even when listed first", &ReleaseDates{Results: []ReleaseDatesCountry{
			rd("GB", ReleaseDate{Certification: "15", Type: 3}),
			rd("US", ReleaseDate{Certification: "R", Type: 3}),
		}}, "R"},
		{"empty premiere is skipped in favour of the real theatrical cert", &ReleaseDates{Results: []ReleaseDatesCountry{
			rd("US",
				ReleaseDate{Certification: "", Type: 1, ReleaseDate: "2019-04-22"},
				ReleaseDate{Certification: "PG-13", Type: 3, ReleaseDate: "2019-04-26"}),
		}}, "PG-13"},
		{"theatrical beats digital and physical regardless of order", &ReleaseDates{Results: []ReleaseDatesCountry{
			rd("US",
				ReleaseDate{Certification: "Unrated", Type: 5, ReleaseDate: "2019-08-01"},
				ReleaseDate{Certification: "R", Type: 4, ReleaseDate: "2019-07-01"},
				ReleaseDate{Certification: "PG-13", Type: 3, ReleaseDate: "2019-06-01"}),
		}}, "PG-13"},
		{"limited theatrical beats premiere and digital", &ReleaseDates{Results: []ReleaseDatesCountry{
			rd("US",
				ReleaseDate{Certification: "R", Type: 4},
				ReleaseDate{Certification: "NC-17", Type: 1},
				ReleaseDate{Certification: "PG", Type: 2}),
		}}, "PG"},
		{"digital-only title falls back to the digital cert", &ReleaseDates{Results: []ReleaseDatesCountry{
			rd("US", ReleaseDate{Certification: "TV-14", Type: 4}),
		}}, "TV-14"},
		{"several theatrical releases: earliest wins, so a re-rating does not displace the original", &ReleaseDates{Results: []ReleaseDatesCountry{
			rd("US",
				ReleaseDate{Certification: "PG", Type: 3, ReleaseDate: "2012-03-09"},
				ReleaseDate{Certification: "PG-13", Type: 3, ReleaseDate: "1975-06-20"},
				ReleaseDate{Certification: "R", Type: 3, ReleaseDate: "1999-01-01"}),
		}}, "PG-13"},
		{"country code is case-insensitive", &ReleaseDates{Results: []ReleaseDatesCountry{
			rd("us", ReleaseDate{Certification: "G", Type: 3}),
		}}, "G"},
		{"certification is trimmed but otherwise raw", &ReleaseDates{Results: []ReleaseDatesCountry{
			rd("US", ReleaseDate{Certification: " NC-17 ", Type: 3}),
		}}, "NC-17"},
		{"NR placeholder is not a rating: unrated", &ReleaseDates{Results: []ReleaseDatesCountry{
			rd("US", ReleaseDate{Certification: "NR", Type: 3}),
		}}, ""},
		{"Not Rated and Unrated placeholders on every release: unrated", &ReleaseDates{Results: []ReleaseDatesCountry{
			rd("US", ReleaseDate{Certification: "Not Rated", Type: 3}, ReleaseDate{Certification: " unrated ", Type: 4}),
		}}, ""},
		{"placeholder theatrical entry is skipped for a real digital cert", &ReleaseDates{Results: []ReleaseDatesCountry{
			rd("US", ReleaseDate{Certification: "NR", Type: 3}, ReleaseDate{Certification: "R", Type: 4}),
		}}, "R"},
		{"unknown release type ranks last but is still usable", &ReleaseDates{Results: []ReleaseDatesCountry{
			rd("US", ReleaseDate{Certification: "G", Type: 99}),
		}}, "G"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := USMovieCertification(c.in); got != c.want {
				t.Errorf("got %q, want %q", got, c.want)
			}
		})
	}
}

func TestNormalizeCertification(t *testing.T) {
	cases := map[string]string{
		"":           "",
		"   ":        "",
		"NR":         "",
		"nr":         "",
		" NR ":       "",
		"Not Rated":  "",
		"NOT RATED":  "",
		"Unrated":    "",
		"unrated":    "",
		"PG-13":      "PG-13",
		"  TV-MA\t":  "TV-MA",
		"NC-17":      "NC-17",
		"Unrated PG": "Unrated PG", // only the exact placeholders are unrated
	}
	for in, want := range cases {
		if got := NormalizeCertification(in); got != want {
			t.Errorf("NormalizeCertification(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestUSTVContentRating(t *testing.T) {
	cases := []struct {
		name string
		in   *ContentRatings
		want string
	}{
		{"nil block", nil, ""},
		{"empty", &ContentRatings{}, ""},
		{"no US entry", &ContentRatings{Results: []ContentRatingEntry{
			{ISO3166_1: "GB", Rating: "15"}, {ISO3166_1: "DE", Rating: "16"},
		}}, ""},
		{"US entry with empty rating", &ContentRatings{Results: []ContentRatingEntry{
			{ISO3166_1: "US", Rating: ""},
		}}, ""},
		{"NR is unrated", &ContentRatings{Results: []ContentRatingEntry{
			{ISO3166_1: "US", Rating: "NR"},
		}}, ""},
		{"Not Rated then a real rating", &ContentRatings{Results: []ContentRatingEntry{
			{ISO3166_1: "US", Rating: "Not Rated"}, {ISO3166_1: "US", Rating: "TV-PG"},
		}}, "TV-PG"},
		{"rating is trimmed", &ContentRatings{Results: []ContentRatingEntry{
			{ISO3166_1: "US", Rating: "  TV-Y7 "},
		}}, "TV-Y7"},
		{"US rating", &ContentRatings{Results: []ContentRatingEntry{
			{ISO3166_1: "GB", Rating: "15"}, {ISO3166_1: "US", Rating: "TV-MA"},
		}}, "TV-MA"},
		{"empty US entry then a real one", &ContentRatings{Results: []ContentRatingEntry{
			{ISO3166_1: "US", Rating: ""}, {ISO3166_1: "US", Rating: "TV-14"},
		}}, "TV-14"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := USTVContentRating(c.in); got != c.want {
				t.Errorf("got %q, want %q", got, c.want)
			}
		})
	}
}

// The two keyword spellings and the appended blocks must all deserialize from raw TMDb JSON.
func TestDetailsParseAppendedBlocks(t *testing.T) {
	const movieJSON = `{
	  "id": 862, "title": "Toy Story",
	  "production_companies": [
	    {"id": 3, "name": "Pixar", "logo_path": "/x.png", "origin_country": "US"},
	    {"id": 2, "name": "Walt Disney Pictures", "logo_path": null, "origin_country": "US"}],
	  "release_dates": {"results": [
	    {"iso_3166_1": "US", "release_dates": [
	      {"certification": "", "type": 1, "release_date": "1995-10-22T00:00:00.000Z"},
	      {"certification": "G", "type": 3, "release_date": "1995-11-22T00:00:00.000Z"}]}]},
	  "keywords": {"keywords": [{"id": 1, "name": "toy"}, {"id": 2, "name": "friendship"}]}
	}`
	var m MovieDetails
	if err := json.Unmarshal([]byte(movieJSON), &m); err != nil {
		t.Fatalf("movie unmarshal: %v", err)
	}
	ex := m.Extras()
	if ex.ContentRating != "G" {
		t.Errorf("movie rating = %q, want G", ex.ContentRating)
	}
	if len(ex.Companies) != 2 || ex.Companies[0] != (Company{ID: 3, Name: "Pixar"}) {
		t.Errorf("movie companies = %+v", ex.Companies)
	}
	if len(ex.Keywords) != 2 || ex.Keywords[1] != (Keyword{ID: 2, Name: "friendship"}) {
		t.Errorf("movie keywords = %+v", ex.Keywords)
	}
	if len(ex.Networks) != 0 {
		t.Errorf("a movie has no networks, got %+v", ex.Networks)
	}

	const tvJSON = `{
	  "id": 1399, "name": "Show",
	  "production_companies": [{"id": 76043, "name": "Revolution Sun Studios"}],
	  "networks": [{"id": 49, "name": "HBO", "logo_path": "/h.png"}],
	  "content_ratings": {"results": [{"iso_3166_1": "US", "rating": "TV-MA"}]},
	  "keywords": {"results": [{"id": 818, "name": "based on novel or book"}]}
	}`
	var tv TVDetails
	if err := json.Unmarshal([]byte(tvJSON), &tv); err != nil {
		t.Fatalf("tv unmarshal: %v", err)
	}
	tx := tv.Extras()
	if tx.ContentRating != "TV-MA" {
		t.Errorf("tv rating = %q, want TV-MA", tx.ContentRating)
	}
	if len(tx.Companies) != 1 || tx.Companies[0].ID != 76043 {
		t.Errorf("tv companies = %+v", tx.Companies)
	}
	if len(tx.Networks) != 1 || tx.Networks[0] != (Company{ID: 49, Name: "HBO"}) {
		t.Errorf("tv networks = %+v", tx.Networks)
	}
	if len(tx.Keywords) != 1 || tx.Keywords[0].ID != 818 {
		t.Errorf("tv keywords (results spelling) = %+v", tx.Keywords)
	}
}

func TestExtrasOfBareDetailsAreEmpty(t *testing.T) {
	var m MovieDetails
	var tv TVDetails
	if ex := m.Extras(); ex.ContentRating != "" || len(ex.Keywords) != 0 || len(ex.Companies) != 0 {
		t.Errorf("bare movie extras = %+v", ex)
	}
	if ex := tv.Extras(); ex.ContentRating != "" || len(ex.Keywords) != 0 || len(ex.Networks) != 0 {
		t.Errorf("bare tv extras = %+v", ex)
	}
}

// fakeTMDb serves canned JSON by path and records every request, so the tests can assert on
// the exact calls made (the "no extra requests" requirement).
type fakeTMDb struct {
	mu      sync.Mutex
	paths   []string
	appends []string
	srv     *httptest.Server
}

func newFakeTMDb(t *testing.T, routes map[string]string) *fakeTMDb {
	t.Helper()
	f := &fakeTMDb{}
	f.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		f.paths = append(f.paths, r.URL.Path)
		f.appends = append(f.appends, r.URL.Query().Get("append_to_response"))
		f.mu.Unlock()
		body, ok := routes[r.URL.Path]
		if !ok {
			w.WriteHeader(http.StatusNotFound)
			_, _ = w.Write([]byte(`{"status_code":34}`))
			return
		}
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(f.srv.Close)
	return f
}

func (f *fakeTMDb) client() *TMDbClient { return NewTMDbClientWithBaseURL("k", f.srv.URL) }

func TestFetchMovieMetadataCapturesRatingWithoutExtraRequests(t *testing.T) {
	f := newFakeTMDb(t, map[string]string{
		"/search/movie": `{"results":[{"id":10,"title":"Up"}]}`,
		"/movie/10": `{"id":10,"title":"Up","release_date":"2009-05-29",
		  "production_companies":[{"id":3,"name":"Pixar"}],
		  "release_dates":{"results":[{"iso_3166_1":"US","release_dates":[{"certification":"PG","type":3,"release_date":"2009-05-29"}]}]},
		  "keywords":{"keywords":[{"id":9,"name":"balloon"}]}}`,
	})
	meta, err := f.client().FetchMovieMetadata(context.Background(), "Up", 2009)
	if err != nil {
		t.Fatalf("FetchMovieMetadata: %v", err)
	}
	if meta.ContentRating != "PG" {
		t.Errorf("ContentRating = %q, want PG", meta.ContentRating)
	}
	if len(meta.Companies) != 1 || meta.Companies[0].Name != "Pixar" {
		t.Errorf("Companies = %+v", meta.Companies)
	}
	if len(meta.Keywords) != 1 || meta.Keywords[0].Name != "balloon" {
		t.Errorf("Keywords = %+v", meta.Keywords)
	}
	// Exactly the two requests the code made before this feature: search + detail.
	if got := strings.Join(f.paths, ","); got != "/search/movie,/movie/10" {
		t.Errorf("requests = %s, want search+detail only", got)
	}
	if ap := f.appends[1]; !strings.Contains(ap, "release_dates") || !strings.Contains(ap, "keywords") || !strings.Contains(ap, "credits") {
		t.Errorf("movie detail append_to_response = %q, want credits,release_dates,keywords", ap)
	}
}

func TestFetchMovieMetadataWithNoUSCertIsEmptyNotError(t *testing.T) {
	f := newFakeTMDb(t, map[string]string{
		"/search/movie": `{"results":[{"id":11,"title":"Foreign"}]}`,
		"/movie/11": `{"id":11,"title":"Foreign",
		  "release_dates":{"results":[{"iso_3166_1":"FR","release_dates":[{"certification":"U","type":3}]}]}}`,
	})
	meta, err := f.client().FetchMovieMetadata(context.Background(), "Foreign", 0)
	if err != nil {
		t.Fatalf("FetchMovieMetadata: %v", err)
	}
	if meta.ContentRating != "" {
		t.Errorf("ContentRating = %q, want empty (unrated)", meta.ContentRating)
	}
}

func TestFetchTVMetadataEpisodeInheritsShowRating(t *testing.T) {
	f := newFakeTMDb(t, map[string]string{
		"/search/tv": `{"results":[{"id":20,"name":"Bluey"}]}`,
		"/tv/20": `{"id":20,"name":"Bluey","first_air_date":"2018-10-01",
		  "production_companies":[{"id":5,"name":"Ludo Studio"}],
		  "networks":[{"id":7,"name":"ABC Kids"}],
		  "content_ratings":{"results":[{"iso_3166_1":"US","rating":"TV-Y"}]},
		  "keywords":{"results":[{"id":4,"name":"dog"}]}}`,
		"/tv/20/season/1/episode/2": `{"id":999,"name":"Hospital","overview":"ep","runtime":7}`,
	})
	meta, err := f.client().FetchTVMetadataWithFallback(context.Background(), "Bluey", "", 1, 2)
	if err != nil {
		t.Fatalf("FetchTVMetadataWithFallback: %v", err)
	}
	if meta.ContentRating != "TV-Y" {
		t.Errorf("episode ContentRating = %q, want the show's TV-Y", meta.ContentRating)
	}
	if meta.EpisodeTitle != "Hospital" {
		t.Errorf("episode lookup lost: EpisodeTitle = %q", meta.EpisodeTitle)
	}
	if len(meta.Networks) != 1 || meta.Networks[0] != (Company{ID: 7, Name: "ABC Kids"}) {
		t.Errorf("Networks = %+v", meta.Networks)
	}
	if len(meta.Companies) != 1 || len(meta.Keywords) != 1 {
		t.Errorf("Companies=%+v Keywords=%+v", meta.Companies, meta.Keywords)
	}
	// search + show detail + episode: unchanged from before.
	if got := strings.Join(f.paths, ","); got != "/search/tv,/tv/20,/tv/20/season/1/episode/2" {
		t.Errorf("requests = %s", got)
	}
	if ap := f.appends[1]; !strings.Contains(ap, "content_ratings") || !strings.Contains(ap, "keywords") {
		t.Errorf("tv detail append_to_response = %q", ap)
	}
}

func TestGetExtrasIsOneRequestWithoutCredits(t *testing.T) {
	f := newFakeTMDb(t, map[string]string{
		"/movie/10": `{"id":10,"release_dates":{"results":[{"iso_3166_1":"US","release_dates":[{"certification":"G","type":3}]}]},
		  "keywords":{"keywords":[{"id":1,"name":"a"}]},"production_companies":[{"id":3,"name":"P"}]}`,
		"/tv/20": `{"id":20,"content_ratings":{"results":[{"iso_3166_1":"US","rating":"TV-G"}]},
		  "keywords":{"results":[{"id":2,"name":"b"}]},"networks":[{"id":7,"name":"N"}]}`,
	})
	c := f.client()
	mx, err := c.GetMovieExtras(context.Background(), 10)
	if err != nil || mx.ContentRating != "G" || len(mx.Keywords) != 1 || len(mx.Companies) != 1 {
		t.Fatalf("GetMovieExtras = %+v, %v", mx, err)
	}
	tx, err := c.GetTVExtras(context.Background(), 20)
	if err != nil || tx.ContentRating != "TV-G" || len(tx.Networks) != 1 || len(tx.Keywords) != 1 {
		t.Fatalf("GetTVExtras = %+v, %v", tx, err)
	}
	if len(f.paths) != 2 {
		t.Errorf("requests = %v, want one per title", f.paths)
	}
	for _, ap := range f.appends {
		if strings.Contains(ap, "credits") {
			t.Errorf("backfill fetch must not pull credits, append_to_response = %q", ap)
		}
	}
}

func TestNon200IsATypedAPIError(t *testing.T) {
	f := newFakeTMDb(t, map[string]string{})
	_, err := f.client().GetMovieExtras(context.Background(), 404)
	var apiErr *APIError
	if !errors.As(err, &apiErr) || apiErr.Status != http.StatusNotFound {
		t.Fatalf("err = %v, want *APIError with status 404", err)
	}
	if !strings.HasPrefix(err.Error(), "tmdb api error: 404") {
		t.Errorf("error text changed: %q", err.Error())
	}
}
