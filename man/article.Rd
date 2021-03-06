% Generated by roxygen2: do not edit by hand
% Please edit documentation in R/article.R
\name{article}
\alias{article}
\title{Create a new article (S3 class)}
\usage{
article(..., quiet = FALSE)
}
\arguments{
\item{...}{Named arguments giving the components of an article:
id, authors, title, editor, reviewers, status}

\item{quiet}{if \code{TRUE} suppresses failure messages.}
}
\description{
This function will always succeed: if the article is not parseable it will
print an error message and return a unparsed blob. This ensures that
information is not lost even if some articles have parsing errors.
}
