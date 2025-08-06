# Optimize IMDb Access Strategy & Complete Scraper Consolidation

## Problem
While we've achieved excellent modularization (>95% code reuse), we have **inconsistent IMDb access patterns** that lead to unnecessary costs and complexity:

1. **Inconsistent Strategy**: Some scrapers use Zyte-first, others use direct-first
2. **Cost Inefficiency**: Using paid Zyte API when free direct access could work  
3. **Code Duplication**: Similar HTTP fetching logic across multiple scrapers

## Current State Analysis

### Direct HTTPoison (Free) - PREFERRED ✅
- `UnifiedFestivalScraper.ex:83` - Uses direct HTTP first
- `ImdbCanonicalScraper.ex:620` - Uses direct HTTP with Zyte fallback

### Zyte API (Paid) - Should be FALLBACK ONLY ⚠️
- `VeniceFilmFestivalScraper.ex:56` - Uses Zyte as primary method
- `OscarScraper.ex` - Uses Zyte exclusively  
- `ImdbOscarScraper.ex` - Uses Zyte exclusively

## Cost Impact Analysis
- **Current**: Mixed strategy leads to unnecessary Zyte API calls
- **Zyte Cost**: ~$0.001-0.01 per request depending on complexity
- **Potential Savings**: 60-80% reduction in Zyte usage by implementing free-first strategy

## Proposed Solution

### 1. Unified HTTP Client Module
Create `lib/cinegraph/http/imdb_client.ex`:

```elixir
defmodule Cinegraph.Http.ImdbClient do
  @moduledoc """
  Unified HTTP client for IMDb scraping with free-first, paid-fallback strategy.
  
  Strategy:
  1. Try direct HTTPoison.get (free, fast)
  2. If blocked/failed, fallback to Zyte API (paid, reliable)
  3. Consistent retry logic and rate limiting
  """

  def fetch_with_fallback(url, opts \\ []) do
    case fetch_direct(url, opts) do
      {:ok, html} -> 
        Logger.info("Direct fetch successful for #{url}")
        {:ok, html}
      {:error, reason} -> 
        Logger.info("Direct fetch failed (#{reason}), trying Zyte fallback")
        fetch_with_zyte(url, opts)
    end
  end

  defp fetch_direct(url, opts) do
    # Standardized direct HTTP implementation
    # Headers, timeouts, retry logic
  end

  defp fetch_with_zyte(url, opts) do
    # Standardized Zyte API implementation
    # Only called when direct method fails
  end
end
```

### 2. Update All Scrapers to Use Unified Client
Replace inconsistent HTTP handling in:
- `VeniceFilmFestivalScraper` - Change from Zyte-first to unified client
- `ImdbOscarScraper` - Change from Zyte-only to unified client  
- `OscarScraper` - Change from Zyte-only to unified client

### 3. Consolidate Redundant Scrapers
- **Merge `OscarScraper`** functionality into `ImdbOscarScraper`
- **Standardize `VeniceFilmFestivalScraper`** to use unified client
- **Remove duplicate** HTTP handling code across scrapers

## Expected Benefits

| Metric | Current | After Optimization |
|--------|---------|-------------------|
| **Code Reuse** | >95% | >98% |
| **HTTP Clients** | 5+ implementations | 1 unified client |
| **Cost Strategy** | Mixed (inconsistent) | Free-first, paid-fallback |
| **Zyte API Calls** | High usage | 60-80% reduction |
| **Maintenance** | Multiple patterns | Single pattern |
| **Reliability** | Varies by scraper | Consistent across all |

## Implementation Plan

### Phase 1: Unified HTTP Client (Week 1)
- [ ] Create `Cinegraph.Http.ImdbClient` module
- [ ] Implement free-first, paid-fallback strategy  
- [ ] Add standardized retry logic and rate limiting
- [ ] Add monitoring for request success rates by method
- [ ] Unit tests for both direct and Zyte fallback paths

### Phase 2: Scraper Migration (Week 2)
- [ ] Update `VeniceFilmFestivalScraper` to use `ImdbClient`
- [ ] Update `ImdbOscarScraper` to use `ImdbClient`
- [ ] Update any remaining scrapers using direct HTTP calls
- [ ] Remove duplicate HTTP handling implementations
- [ ] Integration tests to ensure functionality maintained

### Phase 3: Consolidation & Optimization (Week 3)
- [ ] Merge `OscarScraper` functionality into `ImdbOscarScraper`
- [ ] Remove redundant scraper modules
- [ ] Add monitoring dashboard for free vs paid request ratios
- [ ] Performance testing and optimization
- [ ] Documentation updates

## Success Criteria
- [ ] **Consistency**: All IMDb scrapers use unified free-first, paid-fallback strategy
- [ ] **Cost Reduction**: Zyte API usage reduced by 60-80% (only when direct fails)
- [ ] **Code Quality**: Single HTTP client implementation across all scrapers
- [ ] **Functionality**: All existing festival import functionality maintained
- [ ] **Monitoring**: Clear visibility into request method success rates and costs

## Risk Mitigation
- **Rollback Plan**: Keep existing scraper implementations until unified client is proven
- **A/B Testing**: Test unified client on non-critical operations first
- **Monitoring**: Real-time alerts if success rates drop below baseline
- **Gradual Migration**: Migrate scrapers one at a time to isolate issues

## Related Issues
- Builds upon completed modularization work from #169
- Addresses cost optimization identified in audit
- Improves maintainability of scraping infrastructure

---

This optimization will complete the modularization goals while significantly reducing operational costs and improving code maintainability.