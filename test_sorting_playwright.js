const { chromium } = require('playwright');

async function runTests() {
  const browser = await chromium.launch({ headless: false });
  
  try {
    const page = await browser.newPage();
    
    console.log('=== Testing Movie Sorting with Playwright ===\n');
    
    // Navigate to movies page
    await page.goto('http://localhost:4001/movies');
    await page.waitForSelector('select#sort');
    
    // Test each sort option
    const sortOptions = [
      { value: 'release_date_desc', label: 'Release Date (Newest)' },
      { value: 'release_date', label: 'Release Date (Oldest)' },
      { value: 'title', label: 'Title (A-Z)' },
      { value: 'title_desc', label: 'Title (Z-A)' },
      { value: 'rating', label: 'Rating (Highest)' },
      { value: 'popularity', label: 'Popularity' }
    ];
    
    for (const option of sortOptions) {
      console.log(`Testing: ${option.label} (${option.value})`);
      
      // Select the sort option
      await page.selectOption('select#sort', option.value);
      
      // Wait for the URL to update (LiveView will push a patch)
      await page.waitForURL(url => url.href.includes(`sort=${option.value}`), { timeout: 5000 });
    
    // Check if the selected value matches
    const selectedValue = await page.$eval('select#sort', el => el.value);
    
    if (selectedValue === option.value) {
      console.log(`  ✅ Correct option is selected: ${selectedValue}`);
    } else {
      console.log(`  ❌ Wrong option selected. Expected: ${option.value}, Got: ${selectedValue}`);
    }
    
    // Check the URL to verify the sort parameter
    const currentUrl = page.url();
    if (currentUrl.includes(`sort=${option.value}`)) {
      console.log(`  ✅ URL contains correct sort parameter`);
    } else {
      console.log(`  ⚠️  URL doesn't contain expected sort parameter`);
    }
    
    // Get the first few movie titles to verify sorting
    const movieTitles = await page.$$eval('.group h3', elements => 
      elements.slice(0, 3).map(el => el.textContent.trim())
    );
    
    if (movieTitles.length > 0) {
      console.log(`  First 3 movies: ${movieTitles.join(', ')}`);
    }
    
    console.log('');
  }
  
    console.log('=== Test Complete ===');
    
    // Keep browser open for a moment to see the final state
    await page.waitForTimeout(2000);
    
  } catch (error) {
    console.error('Test failed:', error);
    process.exit(1);
  } finally {
    await browser.close();
  }
}

runTests();