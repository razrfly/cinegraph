defmodule Cinegraph.RateLimiter do
  @moduledoc """
  Token bucket rate limiter for API calls.
  
  TMDb allows 40 requests per 10 seconds.
  """
  
  use GenServer
  require Logger
  
  @tmdb_bucket_size 40
  @tmdb_refill_interval 10_000  # 10 seconds in milliseconds
  @tmdb_refill_amount 40
  
  # Client API
  
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  @doc """
  Attempts to consume a token for an API call.
  Returns :ok if a token was available, or {:error, :rate_limited} if not.
  """
  def check_rate(api \\ :tmdb) do
    GenServer.call(__MODULE__, {:check_rate, api})
  end
  
  @doc """
  Waits until a token is available, then consumes it.
  This will block until rate limit allows the request.
  """
  def wait_for_token(api \\ :tmdb) do
    case check_rate(api) do
      :ok -> 
        :ok
      {:error, :rate_limited} ->
        # Wait a bit and try again
        Process.sleep(500)
        wait_for_token(api)
    end
  end
  
  @doc """
  Gets current token count for monitoring.
  """
  def get_tokens(api \\ :tmdb) do
    GenServer.call(__MODULE__, {:get_tokens, api})
  end
  
  # Server callbacks
  
  @impl true
  def init(_opts) do
    # Schedule the first refill
    schedule_refill(:tmdb, @tmdb_refill_interval)
    
    state = %{
      tmdb: %{
        tokens: @tmdb_bucket_size,
        max_tokens: @tmdb_bucket_size,
        refill_amount: @tmdb_refill_amount,
        refill_interval: @tmdb_refill_interval
      }
    }
    
    {:ok, state}
  end
  
  @impl true
  def handle_call({:check_rate, api}, _from, state) do
    bucket = Map.get(state, api)
    
    if bucket.tokens > 0 do
      # Consume a token
      new_bucket = %{bucket | tokens: bucket.tokens - 1}
      new_state = Map.put(state, api, new_bucket)
      
      {:reply, :ok, new_state}
    else
      {:reply, {:error, :rate_limited}, state}
    end
  end
  
  @impl true
  def handle_call({:get_tokens, api}, _from, state) do
    bucket = Map.get(state, api)
    {:reply, bucket.tokens, state}
  end
  
  @impl true
  def handle_info({:refill, api}, state) do
    bucket = Map.get(state, api)
    
    # Refill tokens up to the maximum
    new_tokens = min(bucket.tokens + bucket.refill_amount, bucket.max_tokens)
    new_bucket = %{bucket | tokens: new_tokens}
    new_state = Map.put(state, api, new_bucket)
    
    Logger.debug("Rate limiter refilled #{api} bucket to #{new_tokens} tokens")
    
    # Schedule next refill
    schedule_refill(api, bucket.refill_interval)
    
    {:noreply, new_state}
  end
  
  defp schedule_refill(api, interval) do
    Process.send_after(self(), {:refill, api}, interval)
  end
end