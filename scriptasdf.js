const fs = require('fs');
const path = require('path');

const folderPath = './images'; // your folder path

fs.readdir(folderPath, (err, files) => {
  if (err) throw err;

  const fileData = files.map(file => {
    const stats = fs.statSync(path.join(folderPath, file));
    return { file, ctime: stats.ctime };
  });

  fileData.sort((a, b) => a.ctime - b.ctime);

  fileData.forEach(f => console.log(f.file));
});
