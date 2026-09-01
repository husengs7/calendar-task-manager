/**
 * Google Apps Script for syncing work calendar events to private calendar
 * Deployed as a Web App (Execute as: Me, Access: Anyone)
 */
function doPost(e) {
  try {
    const data = JSON.parse(e.postData.contents);
    const calendar = CalendarApp.getDefaultCalendar();
    const events = data.events || [];
    
    let created = 0;
    let skipped = 0;

    events.forEach(item => {
      const startTime = new Date(item.startTime);
      const endTime = new Date(item.endTime);
      const title = item.title;
      
      // 同時間帯の同一タイトル重複チェック
      const existing = calendar.getEvents(startTime, endTime);
      const alreadyExists = existing.some(ev => ev.getTitle() === title);
      
      if (!alreadyExists) {
        calendar.createEvent(title, startTime, endTime, {
          description: "会社のカレンダーから自動同期された予定"
        });
        created++;
      } else {
        skipped++;
      }
    });

    return ContentService.createTextOutput(JSON.stringify({
      status: "success",
      total: events.length,
      created: created,
      skipped: skipped
    })).setMimeType(ContentService.MimeType.JSON);

  } catch (err) {
    return ContentService.createTextOutput(JSON.stringify({
      status: "error",
      message: err.toString()
    })).setMimeType(ContentService.MimeType.JSON);
  }
}
