# Testing the Movie Lists UI

## Current State
- Database has been cleared and contains only the 5 original lists
- All movie data has been removed (clean slate)
- The new UI is ready to test

## Test Steps

### 1. Start the Server
```bash
mix phx.server
```

### 2. Navigate to Import Dashboard
Visit: http://localhost:4001/import

### 3. Test the Movie Lists Management
Scroll down to the "Manage Movie Lists" section. You should see:
- A table with 5 lists (all the original hardcoded ones)
- Each list shows: Name, Source (IMDB), Category, Movies (0), Last Import (Never), Status (Active)
- Action buttons: Enable/Disable, Edit, Delete, View →

### 4. Test Adding a New List
1. Click the "+ Add New List" button
2. A modal should appear with fields:
   - List URL (try: https://www.imdb.com/list/ls000004717/)
   - List Name (e.g., "AFI's 100 Greatest American Films")
   - Source Key (e.g., "afi_100")
   - Category (select from dropdown)
   - Description (optional)
   - Checkbox for "tracks awards"
3. Fill in the form and click "Add"
4. The modal should close and the new list should appear in the table

### 5. Test Editing a List
1. Click "Edit" on any list
2. The modal should open with pre-filled data
3. Note that "Source Key" field is readonly (grayed out)
4. Change some fields (name, category, etc.)
5. Click "Update"
6. The changes should be reflected in the table

### 6. Test Deleting a List
1. Add a test list first (so you don't delete important ones)
2. Click "Delete" on the test list
3. A browser confirmation dialog should appear
4. Click OK to confirm
5. The list should disappear from the table

### 7. Test Enable/Disable
1. Click "Disable" on any list
2. The button should change to "Enable" and the row should become semi-transparent
3. Click "Enable" to re-activate it

### 8. Test Cancel Functionality
1. Click "+ Add New List"
2. Fill in some data
3. Click "Cancel" or click the gray background
4. The modal should close without saving

### 9. Test the Canonical Import Dropdown
1. Look at the "Canonical Movie Lists" section above
2. The dropdown should show all active lists
3. If you disabled a list, it should not appear in the dropdown
4. If you added a new list, it should appear in the dropdown

## Expected Behavior
- All CRUD operations should work smoothly
- The modal should be responsive and close properly
- Error messages should appear if validation fails (e.g., duplicate source_key)
- The table should update immediately after any operation
- The canonical lists dropdown should stay in sync with active lists

## Sample IMDB Lists to Test With
- AFI's 100 Years...100 Movies: https://www.imdb.com/list/ls000004717/
- They Shoot Pictures Top 1000: https://www.imdb.com/list/ls075295187/
- Edgar Wright's 1000 Favorite Movies: https://www.imdb.com/list/ls024119532/
- Letterboxd Top 250: https://www.imdb.com/list/ls567380976/