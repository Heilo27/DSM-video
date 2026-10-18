// Package metadata provides integration with external metadata providers.
package metadata

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const (
	tmdbBaseURL  = "https://api.themoviedb.org/3"
	tmdbImageURL = "https://image.tmdb.org/t/p"
)

// ImageSize represents TMDb image sizes.
type ImageSize string

const (
	ImageSizeOriginal ImageSize = "original"
	// TASK-913: w1280 and w780 exist ONLY in TMDb's backdrop ladder, not the poster one.
	// Without them the widest rung was w500, so a 16:9 TV rail card asking for w=760 fell
	// straight through to `original` and pulled a multi-megabyte source image per card.
	// TMDb serves a poster request for these sizes as a redirect to the nearest poster
	// width, so they are safe to request for either type.
	ImageSizeW1280 ImageSize = "w1280"
	ImageSizeW780  ImageSize = "w780"
	ImageSizeW500  ImageSize = "w500"
	ImageSizeW342  ImageSize = "w342"
	ImageSizeW185  ImageSize = "w185"
	ImageSizeW92   ImageSize = "w92"
)

// TMDbClient handles communication with The Movie Database API.
type TMDbClient struct {
	apiKey     string
	baseURL    string
	httpClient *http.Client
}

// NewTMDbClient creates a new TMDb API client.
func NewTMDbClient(apiKey string) *TMDbClient {
	return NewTMDbClientWithBaseURL(apiKey, tmdbBaseURL)
}

// NewTMDbClientWithBaseURL is NewTMDbClient against a different API root. Production uses
// NewTMDbClient; this exists so tests can point the client at a local fake and assert on
// the exact requests it makes.
func NewTMDbClientWithBaseURL(apiKey, baseURL string) *TMDbClient {
	return &TMDbClient{
		apiKey:  apiKey,
		baseURL: baseURL,
		httpClient: &http.Client{
			Timeout: 10 * time.Second,
		},
	}
}

// MovieResult represents a movie from TMDb search results.
type MovieResult struct {
	ID            int     `json:"id"`
	Title         string  `json:"title"`
	OriginalTitle string  `json:"original_title"`
	Overview      string  `json:"overview"`
	ReleaseDate   string  `json:"release_date"`
	PosterPath    string  `json:"poster_path"`
	BackdropPath  string  `json:"backdrop_path"`
	VoteAverage   float64 `json:"vote_average"`
	VoteCount     int     `json:"vote_count"`
	Popularity    float64 `json:"popularity"`
	GenreIDs      []int   `json:"genre_ids"`
	Adult         bool    `json:"adult"`
}

// TVResult represents a TV show from TMDb search results.
type TVResult struct {
	ID            int      `json:"id"`
	Name          string   `json:"name"`
	OriginalName  string   `json:"original_name"`
	Overview      string   `json:"overview"`
	FirstAirDate  string   `json:"first_air_date"`
	PosterPath    string   `json:"poster_path"`
	BackdropPath  string   `json:"backdrop_path"`
	VoteAverage   float64  `json:"vote_average"`
	VoteCount     int      `json:"vote_count"`
	Popularity    float64  `json:"popularity"`
	GenreIDs      []int    `json:"genre_ids"`
	OriginCountry []string `json:"origin_country"`
}

// MovieDetails contains detailed information about a movie.
type MovieDetails struct {
	ID            int      `json:"id"`
	Title         string   `json:"title"`
	OriginalTitle string   `json:"original_title"`
	Overview      string   `json:"overview"`
	ReleaseDate   string   `json:"release_date"`
	PosterPath    string   `json:"poster_path"`
	BackdropPath  string   `json:"backdrop_path"`
	VoteAverage   float64  `json:"vote_average"`
	VoteCount     int      `json:"vote_count"`
	Runtime       int      `json:"runtime"`
	Tagline       string   `json:"tagline"`
	Status        string   `json:"status"`
	Revenue       int64    `json:"revenue"`
	Budget        int64    `json:"budget"`
	IMDbID        string   `json:"imdb_id"`
	Genres        []Genre  `json:"genres"`
	Credits       *Credits `json:"credits,omitempty"`
	// ProductionCompanies, ReleaseDates and Keywords ride along on the detail call via
	// append_to_response (no extra request).
	ProductionCompanies []Company     `json:"production_companies"`
	ReleaseDates        *ReleaseDates `json:"release_dates,omitempty"`
	Keywords            *KeywordList  `json:"keywords,omitempty"`
}

// TVDetails contains detailed information about a TV show.
type TVDetails struct {
	ID               int       `json:"id"`
	Name             string    `json:"name"`
	OriginalName     string    `json:"original_name"`
	Overview         string    `json:"overview"`
	FirstAirDate     string    `json:"first_air_date"`
	LastAirDate      string    `json:"last_air_date"`
	PosterPath       string    `json:"poster_path"`
	BackdropPath     string    `json:"backdrop_path"`
	VoteAverage      float64   `json:"vote_average"`
	VoteCount        int       `json:"vote_count"`
	NumberOfSeasons  int       `json:"number_of_seasons"`
	NumberOfEpisodes int       `json:"number_of_episodes"`
	Status           string    `json:"status"`
	Tagline          string    `json:"tagline"`
	EpisodeRunTime   []int     `json:"episode_run_time"`
	Genres           []Genre   `json:"genres"`
	Networks         []Network `json:"networks"`
	Credits          *Credits  `json:"credits,omitempty"`
	// ProductionCompanies, ContentRatings and Keywords ride along on the detail call via
	// append_to_response (no extra request). Networks is a base field of the response.
	ProductionCompanies []Company       `json:"production_companies"`
	ContentRatings      *ContentRatings `json:"content_ratings,omitempty"`
	Keywords            *KeywordList    `json:"keywords,omitempty"`
}

// TVEpisode contains information about a TV episode.
type TVEpisode struct {
	ID            int     `json:"id"`
	Name          string  `json:"name"`
	Overview      string  `json:"overview"`
	AirDate       string  `json:"air_date"`
	SeasonNumber  int     `json:"season_number"`
	EpisodeNumber int     `json:"episode_number"`
	StillPath     string  `json:"still_path"`
	VoteAverage   float64 `json:"vote_average"`
	VoteCount     int     `json:"vote_count"`
	Runtime       int     `json:"runtime"`
}

// ReleaseDates is TMDb's per-country movie release list. It is the shape of both the
// `release_dates` block appended to /movie/{id} and the standalone /movie/{id}/release_dates
// response, so one type parses either.
type ReleaseDates struct {
	Results []ReleaseDatesCountry `json:"results"`
}

// ReleaseDatesCountry is one country's releases of a movie.
type ReleaseDatesCountry struct {
	ISO3166_1    string        `json:"iso_3166_1"`
	ReleaseDates []ReleaseDate `json:"release_dates"`
}

// ReleaseDate is a single release of a movie in one country. Type is TMDb's enum:
// 1 Premiere, 2 Theatrical (limited), 3 Theatrical, 4 Digital, 5 Physical, 6 TV.
type ReleaseDate struct {
	Certification string `json:"certification"`
	Type          int    `json:"type"`
	ReleaseDate   string `json:"release_date"`
}

// ContentRatings is TMDb's per-country TV rating list. Same dual role as ReleaseDates:
// the appended block on /tv/{id} and the standalone /tv/{id}/content_ratings response.
type ContentRatings struct {
	Results []ContentRatingEntry `json:"results"`
}

// ContentRatingEntry is one country's rating of a TV show.
type ContentRatingEntry struct {
	ISO3166_1 string `json:"iso_3166_1"`
	Rating    string `json:"rating"`
}

// Company is a TMDb production company. TMDb's company ids and network ids are SEPARATE id
// spaces (company 2 is Walt Disney Pictures, network 2 is ABC), so a Company must always be
// stored alongside which kind of list it came from.
type Company struct {
	ID   int    `json:"id"`
	Name string `json:"name"`
}

// Keyword is a TMDb keyword (theme tag), e.g. "christmas".
type Keyword struct {
	ID   int    `json:"id"`
	Name string `json:"name"`
}

// KeywordList parses TMDb's keyword block. The two media types spell it differently:
// movies as {"keywords":[...]}, TV as {"results":[...]}. Exactly one is populated.
type KeywordList struct {
	Keywords []Keyword `json:"keywords"`
	Results  []Keyword `json:"results"`
}

// All returns whichever list the response carried.
func (k *KeywordList) All() []Keyword {
	if k == nil {
		return nil
	}
	if len(k.Keywords) > 0 {
		return k.Keywords
	}
	return k.Results
}

// Extras is everything beyond core metadata that the detail call carries for free: the US
// rating plus the studio and theme tags used for browsing by collection. It is also what the
// backfill fetches for a title that was enriched before these existed.
type Extras struct {
	ContentRating string // raw US certification; "" = none (unrated)
	Companies     []Company
	Networks      []Company // TV only
	Keywords      []Keyword
}

// Extras gathers the movie's rating, studios and keywords.
func (d *MovieDetails) Extras() Extras {
	return Extras{
		ContentRating: d.USCertification(),
		Companies:     d.ProductionCompanies,
		Keywords:      d.Keywords.All(),
	}
}

// Extras gathers the show's rating, studios, networks and keywords.
func (d *TVDetails) Extras() Extras {
	nets := make([]Company, 0, len(d.Networks))
	for _, n := range d.Networks {
		nets = append(nets, Company{ID: n.ID, Name: n.Name})
	}
	return Extras{
		ContentRating: d.USContentRating(),
		Companies:     d.ProductionCompanies,
		Networks:      nets,
		Keywords:      d.Keywords.All(),
	}
}

// Genre represents a genre.
type Genre struct {
	ID   int    `json:"id"`
	Name string `json:"name"`
}

// Network represents a TV network.
type Network struct {
	ID       int    `json:"id"`
	Name     string `json:"name"`
	LogoPath string `json:"logo_path"`
}

// Credits contains cast and crew information.
type Credits struct {
	Cast []CastMember `json:"cast"`
	Crew []CrewMember `json:"crew"`
}

// CastMember represents an actor in a movie or TV show.
type CastMember struct {
	ID          int    `json:"id"`
	Name        string `json:"name"`
	Character   string `json:"character"`
	ProfilePath string `json:"profile_path"`
	Order       int    `json:"order"`
}

// Cast sizes. StoredCastSize is how many billed cast members are kept per title for the detail
// screens' photo row (FR-150); LegacyCastNames is how many names the comma-joined cast_names
// column still carries, for the DS Video web plane and for clients that predate cast photos.
const (
	StoredCastSize  = 12
	LegacyCastNames = 5
)

// TopCast returns up to n of the credits' billed cast, in billing order: members with no name
// are dropped, and a person TMDb lists twice (two roles) appears once, under the first billing.
// It is the one place the cast is chosen, shared by the scanner and every manual TMDb fix, so
// the two can never keep different people. Safe on a nil receiver (a detail call made without
// credits).
func (c *Credits) TopCast(n int) []CastMember {
	if c == nil || n <= 0 {
		return nil
	}
	out := make([]CastMember, 0, n)
	seen := make(map[int]bool, n)
	for _, m := range c.Cast {
		if len(out) >= n {
			break
		}
		m.Name = strings.TrimSpace(m.Name)
		if m.Name == "" {
			continue
		}
		if m.ID > 0 {
			if seen[m.ID] {
				continue
			}
			seen[m.ID] = true
		}
		out = append(out, m)
	}
	return out
}

// CastNames is the first n names of members: the value of the legacy cast_names column.
func CastNames(members []CastMember, n int) []string {
	names := make([]string, 0, n)
	for _, m := range members {
		if len(names) >= n {
			break
		}
		names = append(names, m.Name)
	}
	return names
}

// CrewMember represents a crew member.
type CrewMember struct {
	ID          int    `json:"id"`
	Name        string `json:"name"`
	Job         string `json:"job"`
	Department  string `json:"department"`
	ProfilePath string `json:"profile_path"`
}

// searchMoviesResponse is the API response for movie search.
type searchMoviesResponse struct {
	Page         int           `json:"page"`
	Results      []MovieResult `json:"results"`
	TotalPages   int           `json:"total_pages"`
	TotalResults int           `json:"total_results"`
}

// searchTVResponse is the API response for TV search.
type searchTVResponse struct {
	Page         int        `json:"page"`
	Results      []TVResult `json:"results"`
	TotalPages   int        `json:"total_pages"`
	TotalResults int        `json:"total_results"`
}

// SearchMovies searches for movies by title.
func (c *TMDbClient) SearchMovies(ctx context.Context, query string, year int) ([]MovieResult, error) {
	params := url.Values{
		"api_key": {c.apiKey},
		"query":   {query},
	}
	if year > 0 {
		params.Set("year", strconv.Itoa(year))
	}

	reqURL := fmt.Sprintf("%s/search/movie?%s", c.baseURL, params.Encode())

	var resp searchMoviesResponse
	if err := c.doRequest(ctx, reqURL, &resp); err != nil {
		return nil, err
	}

	return resp.Results, nil
}

// SearchTV searches for TV shows by name.
func (c *TMDbClient) SearchTV(ctx context.Context, query string, year int) ([]TVResult, error) {
	params := url.Values{
		"api_key": {c.apiKey},
		"query":   {query},
	}
	if year > 0 {
		params.Set("first_air_date_year", strconv.Itoa(year))
	}

	reqURL := fmt.Sprintf("%s/search/tv?%s", c.baseURL, params.Encode())

	var resp searchTVResponse
	if err := c.doRequest(ctx, reqURL, &resp); err != nil {
		return nil, err
	}

	return resp.Results, nil
}

// GetMovieDetails fetches detailed information about a movie.
func (c *TMDbClient) GetMovieDetails(ctx context.Context, tmdbID int) (*MovieDetails, error) {
	params := url.Values{
		"api_key":            {c.apiKey},
		"append_to_response": {"credits,release_dates,keywords"},
	}
	reqURL := fmt.Sprintf("%s/movie/%d?%s", c.baseURL, tmdbID, params.Encode())

	var details MovieDetails
	if err := c.doRequest(ctx, reqURL, &details); err != nil {
		return nil, err
	}

	return &details, nil
}

// GetTVDetails fetches detailed information about a TV show.
func (c *TMDbClient) GetTVDetails(ctx context.Context, tmdbID int) (*TVDetails, error) {
	params := url.Values{
		"api_key":            {c.apiKey},
		"append_to_response": {"credits,content_ratings,keywords"},
	}
	reqURL := fmt.Sprintf("%s/tv/%d?%s", c.baseURL, tmdbID, params.Encode())

	var details TVDetails
	if err := c.doRequest(ctx, reqURL, &details); err != nil {
		return nil, err
	}

	return &details, nil
}

// GetMovieExtras fetches a movie's rating, studios and keywords WITHOUT credits: the
// lightweight call the backfill makes for a title enriched before these were captured.
// One request, because release_dates and keywords are appended to the detail call.
func (c *TMDbClient) GetMovieExtras(ctx context.Context, tmdbID int) (Extras, error) {
	params := url.Values{
		"api_key":            {c.apiKey},
		"append_to_response": {"release_dates,keywords"},
	}
	var d MovieDetails
	if err := c.doRequest(ctx, fmt.Sprintf("%s/movie/%d?%s", c.baseURL, tmdbID, params.Encode()), &d); err != nil {
		return Extras{}, err
	}
	return d.Extras(), nil
}

// GetTVExtras is GetMovieExtras for a show: rating, studios, networks and keywords in one
// request, without credits.
func (c *TMDbClient) GetTVExtras(ctx context.Context, tmdbID int) (Extras, error) {
	params := url.Values{
		"api_key":            {c.apiKey},
		"append_to_response": {"content_ratings,keywords"},
	}
	var d TVDetails
	if err := c.doRequest(ctx, fmt.Sprintf("%s/tv/%d?%s", c.baseURL, tmdbID, params.Encode()), &d); err != nil {
		return Extras{}, err
	}
	return d.Extras(), nil
}

// GetTVEpisode fetches information about a specific TV episode.
func (c *TMDbClient) GetTVEpisode(ctx context.Context, tvID, season, episode int) (*TVEpisode, error) {
	params := url.Values{
		"api_key": {c.apiKey},
	}
	reqURL := fmt.Sprintf("%s/tv/%d/season/%d/episode/%d?%s", c.baseURL, tvID, season, episode, params.Encode())

	var ep TVEpisode
	if err := c.doRequest(ctx, reqURL, &ep); err != nil {
		return nil, err
	}

	return &ep, nil
}

// ratingRegion is the only certification region DSVideo reads. A title with no entry for it
// is stored as NULL, which means "unrated" — never a guess from another country's scheme.
const ratingRegion = "US"

// releaseTypePriority ranks a TMDb release type for certification purposes: theatrical
// releases carry the rating the MPA actually assigned, so they win over digital, physical
// and TV releases, which are frequently re-certified or left blank. Unknown types rank last.
func releaseTypePriority(t int) int {
	switch t {
	case 3: // Theatrical
		return 0
	case 2: // Theatrical (limited)
		return 1
	case 1: // Premiere
		return 2
	case 4: // Digital
		return 3
	case 5: // Physical
		return 4
	case 6: // TV
		return 5
	default:
		return 6
	}
}

// NormalizeCertification is the single home for cleaning a raw TMDb certification before it
// is stored or compared. It trims whitespace and maps the placeholders TMDb uses for "no
// rating" ("NR", "Not Rated", "Unrated", any case, or empty) to "", which callers store as
// NULL meaning unrated. A placeholder is not a rating: leaving "NR" in the column would make
// an unrated title look like it had a (never-matching) rating instead of none.
func NormalizeCertification(raw string) string {
	c := strings.TrimSpace(raw)
	switch strings.ToLower(c) {
	case "", "nr", "not rated", "unrated":
		return ""
	}
	return c
}

// USMovieCertification picks the US certification (e.g. "PG-13") from a movie's release
// list, or "" if there is none.
//
// A movie has several US releases and they do not all carry a certification: TMDb often
// lists a Premiere with an empty string next to the real Theatrical entry. Empty entries
// are skipped; among the rest the best release type wins (see releaseTypePriority), and
// within a type the earliest release date wins, so a later re-release with a changed
// rating does not displace the original. Ties beyond that keep TMDb's order. The string is
// returned trimmed but otherwise raw: mapping it to an age level is not this package's job.
func USMovieCertification(rd *ReleaseDates) string {
	if rd == nil {
		return ""
	}
	best := ""
	bestPri := 0
	bestDate := ""
	found := false
	for _, country := range rd.Results {
		if !strings.EqualFold(country.ISO3166_1, ratingRegion) {
			continue
		}
		for _, r := range country.ReleaseDates {
			cert := NormalizeCertification(r.Certification)
			if cert == "" {
				continue
			}
			pri := releaseTypePriority(r.Type)
			better := !found || pri < bestPri ||
				(pri == bestPri && r.ReleaseDate != "" && (bestDate == "" || r.ReleaseDate < bestDate))
			if better {
				best, bestPri, bestDate, found = cert, pri, r.ReleaseDate, true
			}
		}
	}
	return best
}

// USTVContentRating picks the US rating (e.g. "TV-MA") from a show's content ratings, or ""
// if there is none. Empty entries are skipped. The string is returned trimmed but raw.
func USTVContentRating(cr *ContentRatings) string {
	if cr == nil {
		return ""
	}
	for _, e := range cr.Results {
		if !strings.EqualFold(e.ISO3166_1, ratingRegion) {
			continue
		}
		if rating := NormalizeCertification(e.Rating); rating != "" {
			return rating
		}
	}
	return ""
}

// USCertification is the movie's US certification, or "" if TMDb has none.
func (d *MovieDetails) USCertification() string { return USMovieCertification(d.ReleaseDates) }

// USContentRating is the show's US rating, or "" if TMDb has none.
func (d *TVDetails) USContentRating() string { return USTVContentRating(d.ContentRatings) }

// GetImageURL constructs a full URL for a TMDb image.
func GetImageURL(path string, size ImageSize) string {
	if path == "" {
		return ""
	}
	return fmt.Sprintf("%s/%s%s", tmdbImageURL, size, path)
}

// APIError is a non-200 answer from TMDb. It is a type, not a bare string, so callers can
// tell "this title does not exist" (404, permanent) from "try again later" (429, 5xx, a bad
// key) — the content-rating backfill must never record the second kind as a finished check.
type APIError struct {
	Status int
	Body   string
}

func (e *APIError) Error() string {
	return fmt.Sprintf("tmdb api error: %d - %s", e.Status, e.Body)
}

// doRequest performs an HTTP request and decodes the JSON response.
func (c *TMDbClient) doRequest(ctx context.Context, reqURL string, result interface{}) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, reqURL, nil)
	if err != nil {
		return fmt.Errorf("create request: %w", err)
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("http request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		// TASK-823: cap the error-body read — a misbehaving upstream must not be able
		// to make us buffer an unbounded error string. 64 KiB is ample for any API error.
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
		return &APIError{Status: resp.StatusCode, Body: string(body)}
	}

	// TASK-823: bound the JSON body too. TMDb detail/search responses are well under
	// this; 8 MiB is a generous ceiling that caps memory on a misbehaving upstream.
	if err := json.NewDecoder(io.LimitReader(resp.Body, 8<<20)).Decode(result); err != nil {
		return fmt.Errorf("decode response: %w", err)
	}

	return nil
}

// VideoMetadata represents enriched metadata for a video file.
type VideoMetadata struct {
	TMDbID        int
	IMDbID        string
	Title         string
	OriginalTitle string
	Overview      string
	Year          int
	ReleaseDate   string
	PosterPath    string
	BackdropPath  string
	Rating        float64
	RatingCount   int
	Runtime       int // minutes
	Genres        []string
	Cast          []string // Top cast names (the legacy cast_names column)
	// CastMembers is the billed cast with TMDb person ids and profile photos (FR-150); Cast is
	// its first LegacyCastNames names.
	CastMembers []CastMember
	Director    string
	// ContentRating is the raw US certification ("PG-13", "TV-MA"). Empty means TMDb has
	// no US certification for the title: stored as NULL, meaning unrated.
	ContentRating string

	// Studio and theme tags for browsing by collection. For an episode these are the
	// SHOW's: TMDb tags shows, not episodes.
	Companies []Company
	Networks  []Company // TV only
	Keywords  []Keyword

	// TV-specific
	SeasonNumber  int
	EpisodeNumber int
	EpisodeTitle  string
	ShowName      string
	ShowTMDbID    int
}

// ParsedFilename contains parsed information from a video filename.
type ParsedFilename struct {
	Title   string
	Year    int
	Season  int
	Episode int
	IsTV    bool
}

// ParseFilename extracts title, year, and episode info from a filename.
var (
	whitespaceRun     = regexp.MustCompile(`\s+`)
	danglingOpenParen = regexp.MustCompile(`\s*\([^)]*$`)
	trailingSeparator = regexp.MustCompile(`[\s\-–—:,.]+$`)
	// Only a hyphen acting as a delimiter (whitespace on at least one side). An intra-word
	// hyphen — "X-Men", "Spider-Man", "Marvel's Agents of S.H.I.E.L.D." — is part of the
	// title and must survive to be searchable.
	delimiterHyphen = regexp.MustCompile(`\s+-+\s*|\s*-+\s+`)
)

// NormalizeTitle cleans a parsed title into something a search engine can match.
//
// Filename parsing expands separators into spaces and slices titles at pattern
// boundaries, which reliably produces two artefacts that make a title unsearchable:
// runs of whitespace (from "A - B" becoming "A   B"), and a dangling "(" left behind
// when a cut lands inside a parenthetical. Both were present in
// "X Men   PRYDE of The X Men (Original", which matched nothing on TMDb and left every
// episode under that folder without artwork.
//
// The transformation is deliberately conservative — it only removes noise that parsing
// introduced. Balanced parentheses are meaningful (a disambiguating year, "Justified
// (2010)") and are preserved. Apostrophes and internal punctuation are left alone.
func NormalizeTitle(title string) string {
	out := whitespaceRun.ReplaceAllString(title, " ")
	out = strings.TrimSpace(out)
	// An unclosed "(" is always parsing damage: a real title would have closed it.
	out = danglingOpenParen.ReplaceAllString(out, "")
	out = trailingSeparator.ReplaceAllString(out, "")
	return strings.TrimSpace(out)
}

func ParseFilename(filename string) ParsedFilename {
	result := ParsedFilename{}

	// Remove extension
	name := strings.TrimSuffix(filename, "."+getExtension(filename))

	// Replace common separators with spaces.
	//
	// Hyphens are handled separately and deliberately. Blanket-replacing them destroyed
	// hyphenated titles — "X-Men" became "X Men", which does not match on TMDb — while
	// only ever being needed for the DELIMITER form " - " that separates a show name from
	// its episode marker. Replacing only a hyphen surrounded by whitespace splits
	// "Show - S01 E01" correctly and leaves "X-Men" and "Spider-Man" intact.
	name = strings.ReplaceAll(name, ".", " ")
	name = strings.ReplaceAll(name, "_", " ")
	name = delimiterHyphen.ReplaceAllString(name, " ")
	// Collapse immediately: every downstream index-based slice below assumes single
	// spacing, and without this the runs survive into the stored title.
	name = whitespaceRun.ReplaceAllString(name, " ")
	name = strings.TrimSpace(name)

	// Check for TV show patterns: S01E02, S01 E02, 1x02, Season 1 Episode 2
	tvPatterns := []struct {
		pattern *regexp.Regexp
		extract func([]string) (int, int)
	}{
		{
			regexp.MustCompile(`(?i)S(\d{1,2})\s*E(\d{1,2})`),
			func(m []string) (int, int) {
				s, _ := strconv.Atoi(m[1])
				e, _ := strconv.Atoi(m[2])
				return s, e
			},
		},
		{
			regexp.MustCompile(`(?i)(\d{1,2})x(\d{1,2})`),
			func(m []string) (int, int) {
				s, _ := strconv.Atoi(m[1])
				e, _ := strconv.Atoi(m[2])
				return s, e
			},
		},
		{
			regexp.MustCompile(`(?i)Season\s*(\d{1,2})\s*Episode\s*(\d{1,2})`),
			func(m []string) (int, int) {
				s, _ := strconv.Atoi(m[1])
				e, _ := strconv.Atoi(m[2])
				return s, e
			},
		},
	}

	for _, tp := range tvPatterns {
		if matches := tp.pattern.FindStringSubmatch(name); matches != nil {
			result.IsTV = true
			result.Season, result.Episode = tp.extract(matches)
			// Title is everything before the match
			idx := tp.pattern.FindStringIndex(name)
			if idx != nil {
				result.Title = strings.TrimSpace(name[:idx[0]])
			}
			break
		}
	}

	// If not TV, extract year for movie
	if !result.IsTV {
		yearPattern := regexp.MustCompile(`\(?(19|20)\d{2}\)?`)
		if matches := yearPattern.FindStringSubmatch(name); matches != nil {
			year, _ := strconv.Atoi(strings.Trim(matches[0], "()"))
			result.Year = year
			// Title is everything before the year.
			//
			// If the year sits INSIDE a parenthetical, cut at the opening "(" instead,
			// so the whole group goes rather than half of it. Slicing at the year index
			// is what produced "X Men PRYDE of The X Men (Original" from
			// "...(Original 1989 Pilot)" — an unbalanced fragment that matches nothing.
			// A parenthetical containing a year is an edition/release note, never part
			// of the searchable title, so removing it whole is also more correct.
			if idx := yearPattern.FindStringIndex(name); idx != nil {
				cut := idx[0]
				if open := strings.LastIndex(name[:cut], "("); open != -1 {
					// Only when the "(" is genuinely unclosed before the year — a
					// balanced group that merely precedes the year must be preserved.
					if !strings.Contains(name[open:cut], ")") {
						cut = open
					}
				}
				result.Title = strings.TrimSpace(name[:cut])
			}
		} else {
			// No year found, use whole name as title
			result.Title = strings.TrimSpace(name)
		}
	}

	// Clean up title - remove quality indicators
	// Strip quality/release tags and everything after them. 360p/480p/576p were absent
	// from this list even though the library is full of SD rips, so those tags survived
	// into stored titles.
	qualityPatterns := regexp.MustCompile(`(?i)\b(360p|480p|576p|720p|1080p|2160p|4k|uhd|hdr|bluray|brrip|webrip|web dl|hdtv|dvdrip|x264|x265|hevc|aac|ac3|dts)\b.*`)
	result.Title = qualityPatterns.ReplaceAllString(result.Title, "")

	// Final pass: repairs any dangling paren or trailing separator the slices above left.
	result.Title = NormalizeTitle(result.Title)

	return result
}

func getExtension(filename string) string {
	parts := strings.Split(filename, ".")
	if len(parts) > 1 {
		return parts[len(parts)-1]
	}
	return ""
}

// FetchMovieMetadata searches TMDb and returns metadata for a movie.
func (c *TMDbClient) FetchMovieMetadata(ctx context.Context, title string, year int) (*VideoMetadata, error) {
	results, err := c.SearchMovies(ctx, title, year)
	if err != nil {
		return nil, err
	}

	if len(results) == 0 {
		// Try without year
		if year > 0 {
			results, err = c.SearchMovies(ctx, title, 0)
			if err != nil {
				return nil, err
			}
		}
		if len(results) == 0 {
			return nil, fmt.Errorf("no results found for: %s", title)
		}
	}

	// Get details for the best match
	best := results[0]
	details, err := c.GetMovieDetails(ctx, best.ID)
	if err != nil {
		return nil, err
	}

	meta := &VideoMetadata{
		TMDbID:        details.ID,
		IMDbID:        details.IMDbID,
		Title:         details.Title,
		OriginalTitle: details.OriginalTitle,
		Overview:      details.Overview,
		ReleaseDate:   details.ReleaseDate,
		PosterPath:    details.PosterPath,
		BackdropPath:  details.BackdropPath,
		Rating:        details.VoteAverage,
		RatingCount:   details.VoteCount,
		Runtime:       details.Runtime,
		ContentRating: details.USCertification(),
		Companies:     details.ProductionCompanies,
		Keywords:      details.Keywords.All(),
	}

	// Extract year from release date
	if len(details.ReleaseDate) >= 4 {
		meta.Year, _ = strconv.Atoi(details.ReleaseDate[:4])
	}

	// Extract genres
	for _, g := range details.Genres {
		meta.Genres = append(meta.Genres, g.Name)
	}

	// Extract cast
	meta.CastMembers = details.Credits.TopCast(StoredCastSize)
	meta.Cast = CastNames(meta.CastMembers, LegacyCastNames)
	if details.Credits != nil {
		// Find director
		for _, c := range details.Credits.Crew {
			if c.Job == "Director" {
				meta.Director = c.Name
				break
			}
		}
	}

	return meta, nil
}

// FetchTVMetadata searches TMDb and returns metadata for a TV episode.
func (c *TMDbClient) FetchTVMetadata(ctx context.Context, showName string, season, episode int) (*VideoMetadata, error) {
	return c.FetchTVMetadataWithFallback(ctx, showName, "", season, episode)
}

// FetchTVMetadataWithFallback searches TMDb for a TV episode, trying progressively
// looser queries before giving up.
//
// A single-shot search was too brittle for a real library. When the parsed title carried
// parsing damage the search returned nothing, the caller stamped metadata_fetched_at, and
// that episode was never looked up again — permanently artwork-less. 476 episodes in the
// live library were in exactly that state.
//
// The ladder, cheapest and most-likely-correct first:
//
//  1. the title as parsed
//  2. the normalized title, if normalization actually changed it
//  3. the containing folder name, which for nested collections is the real show name and
//     is otherwise discarded — the scanner only ever passes the file's basename
//
// Each rung is tried only if the previous returned zero results; a successful search
// short-circuits. An error (network, auth) aborts immediately rather than falling through,
// since retrying a broken connection with a different string is pointless.
func (c *TMDbClient) FetchTVMetadataWithFallback(ctx context.Context, showName, folderName string, season, episode int) (*VideoMetadata, error) {
	attempts := []string{showName}
	if n := NormalizeTitle(showName); n != "" && n != showName {
		attempts = append(attempts, n)
	}
	if f := NormalizeTitle(folderName); f != "" && !containsFold(attempts, f) {
		attempts = append(attempts, f)
	}

	var results []TVResult
	var err error
	for _, q := range attempts {
		if strings.TrimSpace(q) == "" {
			continue
		}
		results, err = c.SearchTV(ctx, q, 0)
		if err != nil {
			return nil, err
		}
		if len(results) > 0 {
			break
		}
	}

	if len(results) == 0 {
		return nil, fmt.Errorf("no results found for: %s", showName)
	}

	// Get show details
	show := results[0]
	showDetails, err := c.GetTVDetails(ctx, show.ID)
	if err != nil {
		return nil, err
	}

	meta := &VideoMetadata{
		ShowTMDbID:    show.ID,
		ShowName:      showDetails.Name,
		Title:         showDetails.Name,
		OriginalTitle: showDetails.OriginalName,
		Overview:      showDetails.Overview,
		PosterPath:    showDetails.PosterPath,
		BackdropPath:  showDetails.BackdropPath,
		Rating:        showDetails.VoteAverage,
		RatingCount:   showDetails.VoteCount,
		SeasonNumber:  season,
		EpisodeNumber: episode,
		// An episode inherits its show's rating: TMDb rates shows, not episodes.
		ContentRating: showDetails.USContentRating(),
	}
	showExtras := showDetails.Extras()
	meta.Companies, meta.Networks, meta.Keywords = showExtras.Companies, showExtras.Networks, showExtras.Keywords

	// Extract year from first air date
	if len(showDetails.FirstAirDate) >= 4 {
		meta.Year, _ = strconv.Atoi(showDetails.FirstAirDate[:4])
	}

	// Extract genres
	for _, g := range showDetails.Genres {
		meta.Genres = append(meta.Genres, g.Name)
	}

	// Extract cast
	meta.CastMembers = showDetails.Credits.TopCast(StoredCastSize)
	meta.Cast = CastNames(meta.CastMembers, LegacyCastNames)

	// Get episode details if season/episode provided
	if season > 0 && episode > 0 {
		epDetails, err := c.GetTVEpisode(ctx, show.ID, season, episode)
		if err == nil {
			meta.TMDbID = epDetails.ID
			meta.EpisodeTitle = epDetails.Name
			meta.Overview = epDetails.Overview // Use episode overview
			meta.Runtime = epDetails.Runtime
			if epDetails.StillPath != "" {
				meta.BackdropPath = epDetails.StillPath
			}
		}
	}

	return meta, nil
}

// containsFold reports whether s appears in list, case-insensitively.
func containsFold(list []string, s string) bool {
	for _, v := range list {
		if strings.EqualFold(v, s) {
			return true
		}
	}
	return false
}
