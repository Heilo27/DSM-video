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
	ImageSizeW500     ImageSize = "w500"
	ImageSizeW342     ImageSize = "w342"
	ImageSizeW185     ImageSize = "w185"
	ImageSizeW92      ImageSize = "w92"
)

// TMDbClient handles communication with The Movie Database API.
type TMDbClient struct {
	apiKey     string
	httpClient *http.Client
}

// NewTMDbClient creates a new TMDb API client.
func NewTMDbClient(apiKey string) *TMDbClient {
	return &TMDbClient{
		apiKey: apiKey,
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
	ID              int     `json:"id"`
	Name            string  `json:"name"`
	OriginalName    string  `json:"original_name"`
	Overview        string  `json:"overview"`
	FirstAirDate    string  `json:"first_air_date"`
	PosterPath      string  `json:"poster_path"`
	BackdropPath    string  `json:"backdrop_path"`
	VoteAverage     float64 `json:"vote_average"`
	VoteCount       int     `json:"vote_count"`
	Popularity      float64 `json:"popularity"`
	GenreIDs        []int   `json:"genre_ids"`
	OriginCountry   []string `json:"origin_country"`
}

// MovieDetails contains detailed information about a movie.
type MovieDetails struct {
	ID            int     `json:"id"`
	Title         string  `json:"title"`
	OriginalTitle string  `json:"original_title"`
	Overview      string  `json:"overview"`
	ReleaseDate   string  `json:"release_date"`
	PosterPath    string  `json:"poster_path"`
	BackdropPath  string  `json:"backdrop_path"`
	VoteAverage   float64 `json:"vote_average"`
	VoteCount     int     `json:"vote_count"`
	Runtime       int     `json:"runtime"`
	Tagline       string  `json:"tagline"`
	Status        string  `json:"status"`
	Revenue       int64   `json:"revenue"`
	Budget        int64   `json:"budget"`
	IMDbID        string  `json:"imdb_id"`
	Genres        []Genre `json:"genres"`
	Credits       *Credits `json:"credits,omitempty"`
}

// TVDetails contains detailed information about a TV show.
type TVDetails struct {
	ID              int       `json:"id"`
	Name            string    `json:"name"`
	OriginalName    string    `json:"original_name"`
	Overview        string    `json:"overview"`
	FirstAirDate    string    `json:"first_air_date"`
	LastAirDate     string    `json:"last_air_date"`
	PosterPath      string    `json:"poster_path"`
	BackdropPath    string    `json:"backdrop_path"`
	VoteAverage     float64   `json:"vote_average"`
	VoteCount       int       `json:"vote_count"`
	NumberOfSeasons int       `json:"number_of_seasons"`
	NumberOfEpisodes int      `json:"number_of_episodes"`
	Status          string    `json:"status"`
	Tagline         string    `json:"tagline"`
	EpisodeRunTime  []int     `json:"episode_run_time"`
	Genres          []Genre   `json:"genres"`
	Networks        []Network `json:"networks"`
	Credits         *Credits  `json:"credits,omitempty"`
}

// TVEpisode contains information about a TV episode.
type TVEpisode struct {
	ID             int     `json:"id"`
	Name           string  `json:"name"`
	Overview       string  `json:"overview"`
	AirDate        string  `json:"air_date"`
	SeasonNumber   int     `json:"season_number"`
	EpisodeNumber  int     `json:"episode_number"`
	StillPath      string  `json:"still_path"`
	VoteAverage    float64 `json:"vote_average"`
	VoteCount      int     `json:"vote_count"`
	Runtime        int     `json:"runtime"`
}

// Genre represents a genre.
type Genre struct {
	ID   int    `json:"id"`
	Name string `json:"name"`
}

// Network represents a TV network.
type Network struct {
	ID   int    `json:"id"`
	Name string `json:"name"`
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

	reqURL := fmt.Sprintf("%s/search/movie?%s", tmdbBaseURL, params.Encode())

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

	reqURL := fmt.Sprintf("%s/search/tv?%s", tmdbBaseURL, params.Encode())

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
		"append_to_response": {"credits"},
	}
	reqURL := fmt.Sprintf("%s/movie/%d?%s", tmdbBaseURL, tmdbID, params.Encode())

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
		"append_to_response": {"credits"},
	}
	reqURL := fmt.Sprintf("%s/tv/%d?%s", tmdbBaseURL, tmdbID, params.Encode())

	var details TVDetails
	if err := c.doRequest(ctx, reqURL, &details); err != nil {
		return nil, err
	}

	return &details, nil
}

// GetTVEpisode fetches information about a specific TV episode.
func (c *TMDbClient) GetTVEpisode(ctx context.Context, tvID, season, episode int) (*TVEpisode, error) {
	params := url.Values{
		"api_key": {c.apiKey},
	}
	reqURL := fmt.Sprintf("%s/tv/%d/season/%d/episode/%d?%s", tmdbBaseURL, tvID, season, episode, params.Encode())

	var ep TVEpisode
	if err := c.doRequest(ctx, reqURL, &ep); err != nil {
		return nil, err
	}

	return &ep, nil
}

// GetImageURL constructs a full URL for a TMDb image.
func GetImageURL(path string, size ImageSize) string {
	if path == "" {
		return ""
	}
	return fmt.Sprintf("%s/%s%s", tmdbImageURL, size, path)
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
		return fmt.Errorf("tmdb api error: %d - %s", resp.StatusCode, string(body))
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
	TMDbID       int
	IMDbID       string
	Title        string
	OriginalTitle string
	Overview     string
	Year         int
	ReleaseDate  string
	PosterPath   string
	BackdropPath string
	Rating       float64
	RatingCount  int
	Runtime      int // minutes
	Genres       []string
	Cast         []string // Top cast names
	Director     string
	ContentRating string

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
	}

	// Extract year from release date
	if len(details.ReleaseDate) >= 4 {
		meta.Year, _ = strconv.Atoi(details.ReleaseDate[:4])
	}

	// Extract genres
	for _, g := range details.Genres {
		meta.Genres = append(meta.Genres, g.Name)
	}

	// Extract cast (top 5)
	if details.Credits != nil {
		for i, c := range details.Credits.Cast {
			if i >= 5 {
				break
			}
			meta.Cast = append(meta.Cast, c.Name)
		}
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
	}

	// Extract year from first air date
	if len(showDetails.FirstAirDate) >= 4 {
		meta.Year, _ = strconv.Atoi(showDetails.FirstAirDate[:4])
	}

	// Extract genres
	for _, g := range showDetails.Genres {
		meta.Genres = append(meta.Genres, g.Name)
	}

	// Extract cast (top 5)
	if showDetails.Credits != nil {
		for i, c := range showDetails.Credits.Cast {
			if i >= 5 {
				break
			}
			meta.Cast = append(meta.Cast, c.Name)
		}
	}

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
