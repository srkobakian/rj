% Generated by roxygen2: do not edit by hand
% Please edit documentation in R/submissions.R
\name{get_submissions}
\alias{get_submissions}
\title{Download submissions.}
\usage{
get_submissions()
}
\description{
Obtains submissions from the Google Sheets spreadsheet and downloads
submission files from Google Drive.
}
\section{Process}{

The function does three things automatically:
\enumerate{
 \item Downloads and extracts submissions into appropriate directories.
 \item Marks submissions as "read" in the spreadsheet.
 \item Uploads acknowledgement emails to gmail account as drafts.
}

The user (editor-in-chief) then:
\enumerate{
 \item Ensures that the files have unzipped correctly (some authors
   incorrectly upload .rar or .tar.gz files) and that the latex
   compiles
 \item Manually sends the draft emails
}
}

