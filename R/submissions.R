sheet_id <- "15Tem82ikjHhNVccZGrHFVdzVjoxAmwaiNwaBE95wu6k"

#' Download submissions.
#'
#' Obtains submissions from the Google Sheets spreadsheet and downloads
#' submission files from Google Drive.
#'
#' @section Process:
#' The function does three things automatically:
#' \enumerate{
#'  \item Downloads and extracts submissions into appropriate directories.
#'  \item Marks submissions as "read" in the spreadsheet.
#'  \item Uploads acknowledgement emails to gmail account as drafts.
#' }
#'
#' The user (editor-in-chief) then:
#' \enumerate{
#'  \item Ensures that the files have unzipped correctly (some authors
#'    incorrectly upload .rar or .tar.gz files) and that the latex
#'    compiles
#'  \item Manually sends the draft emails
#' }
#' @export
get_submissions <- function() {
    cli::cat_line("Downloading new submissions")
    subs <- download_submissions()

    cli::cat_line("Performing automatic checks on submissions")
    # consume_submissions(subs)

    cli::cat_line("Drafting acknowledgements")
    draft_acknowledgements(subs)

    invisible(NULL)
}

#' @importFrom gmailr gmail_auth
authorize <- function(scope) {
    secret_file <- system.file("auth", "client_id.json", package = "rj")
    gmailr::gmail_auth(scope, secret_file = secret_file)
}

extract_files <- function(files, dest) {
    for (file in files) {
        extractor <- switch(tools::file_ext(file),
                            zip = utils::unzip,
                            gz = utils::untar)
        if (is.null(extractor))
            return(NULL)
        extractor(file, exdir = dest)
        unlink(file)
        unlink(file.path(dest, "__MACOSX"), recursive = TRUE)
        exfiles <- list.files(dest, full.names = TRUE)
        nested <- length(exfiles) == 1L && file.info(exfiles)$isdir
        if (nested) {
            subfiles <- list.files(exfiles, full.names=TRUE)
            file.rename(subfiles, paste0(dest, .Platform$file.sep, basename(subfiles)))
            unlink(exfiles, recursive=TRUE)
        }
    }
}

create_submission_directory <- function(id) {
    dir <- file.path(get_articles_path(), "Submissions", format(id))
    dir_create(dir)
    dir
}

as.article.gmail_message <- function(msg, ...) {
    txt <- sub("\\[.*", "", gmailr::body(msg)[[1L]])
    txt <- gsub("\r\n(\r\n)+", "\n", txt)
    dcf <- read.dcf(textConnection(txt))
    dcf <- setNames(dcf, tolower(colnames(dcf)))
    do.call(article, c(dcf, list(...)))
}

#' @importFrom googlesheets4 read_sheet range_write
download_submissions <- function() {
    submissions <- googlesheets4::read_sheet(sheet_id)
    ids <- submissions[["Submission ID"]]
    new_submission <- is.na(ids)
    resub_field <- "If this is a revision or resubmission, enter your submission ID (eg 2020-131)"
    resub_ids <- submissions[[resub_field]][new_submission]
    is_resub <- !is.na(resub_ids)

    # Check that resubmitted articles are not yet rejected (warranting a new ID)
    resub_accepted <- file.exists(file.path(get_articles_path(), "Accepted", resub_ids[is_resub]))
    resub_submitted <- file.exists(file.path(get_articles_path(), "Submissions", resub_ids[is_resub]))
    resub_rejected <- file.exists(file.path(get_articles_path(), "Rejected", resub_ids[is_resub]))
    is_resub[is_resub] <- resub_accepted | resub_submitted

    new_ids <- vector("list", sum(new_submission))

    # Generate IDs
    new_ids[!is_resub] <- future_ids(ids[!new_submission], n = sum(new_submission) - sum(is_resub))
    new_ids[is_resub] <- lapply(resub_ids[is_resub], parse_id)

    new_articles <- submissions[new_submission,]
    new_articles[["Submission ID"]] <- vapply(new_ids, format, character(1L))
    articles <- lapply(split(new_articles, new_articles[["Submission ID"]]),
           function(form) {
               id <- form[["Submission ID"]]
               if(!identical(id, form[[resub_field]])) {
                   path <- create_submission_directory(id)

                   # If the article is a new submission
                   files <- download_submission_file(form[["Upload submission (zip file)"]], path = path)
                   extract_files(files, path)

                   art <- make_article(
                       id = id,
                       authors = str_c(
                           c(
                               str_glue_data(form, "{`Your name:`} <{`Email address`}>"),
                               setdiff(str_trim(str_split(form[["Names of other authors, comma separated"]], ",")[[1]]), form[["Your name:"]])
                           ),
                           collapse = ", "),
                       title = form[["Article title"]],
                       path = path,
                       suppl = form[["If any absolutely essential additional latex packages are required to build your article, please list here separated by commas."]]%NA%"",
                       keywords = form[["Article tags"]]%NA%"",
                       otherids = form[[resub_field]]%NA%""
                   )

                   update_status(art, status = "submitted", date = as.Date(form$Timestamp))
                   cli::cli_alert_success("New submission with ID {id} successfully processed.")
                   return(TRUE)
               } else {
                   # If the article is a re-submission

                   # 1. Get original article
                   art <- as.article(id)
                   path <- art$path
                   path_dir <- basename(dirname(path))
                   if(path_dir != "Submissions") {
                       cli::cli_alert_warning("Re-submission for {id} is replacing an article in the '{path_dir}' folder!")
                   }

                   # 2. Check that the metadata matches
                   matches_title <- art$title == form$`Article title`
                   matches_email <- art$authors[[1]]$email == form$`Email address`
                   if(!matches_title && !matches_email) {
                       cli::cli_alert_danger("Re-submission for {id} does not match original title and email. Contact {form$`Email address`} to clarify.")
                       return(FALSE)
                   }

                   # 3. Zip old submission into /history
                   old_submission <- setdiff(
                       list.files(art$path, include.dirs = TRUE),
                       c("DESCRIPTION", "history")
                   )
                   num_submissions <- length(list.files(file.path(path, "history")))
                   dir_create(file.path(path, "history"))
                   curwd <- setwd(path)
                   zip(
                       zipfile = file.path("history", paste0(num_submissions+1, ".zip")),
                       files = old_submission,
                       flags = "-r9Xmq"
                   )
                   setwd(curwd)

                   # 4. Obtain new submission
                   files <- download_submission_file(form[["Upload submission (zip file)"]], path = path)
                   extract_files(files, path)

                   # 5. Update article DESCRIPTION
                   update_status(art, status = "revision received", date = as.Date(form$Timestamp))

                   cli::cli_alert_success("Re-submission for ID {id} successfully processed.")
                   return(TRUE)
               }
           })
    cli::cli_alert_info("Writing new article IDs to Google Sheets.")
    googlesheets4::range_write(sheet_id, new_articles["Submission ID"], sheet = "Form responses 1", col_names = FALSE,
                              range = str_c(LETTERS[which(names(submissions) == "Submission ID")], range(which(new_submission)) + 1, collapse = ":"))

    articles
}

#' Generate a new id value.
#'
#' Inspects submissions/, accepted/ and rejected to figure out which
#' id is next in sequence.
#' @param ids XXX
#' @param n No. of ids to generate
#' @export
future_ids <- function(ids, n = 1) {
    ids <- lapply(ids, parse_id)

    this_year <- Filter(function(x) x$year == year(), ids)

    seqs <- vapply(this_year, function(x) x$seq, integer(1))
    max_seq <- if (is_empty(seqs)) 0 else max(seqs)
    lapply(max_seq + seq_len(n), id, year = year())
}

#' @importFrom stringr str_remove fixed
download_submission_file <- function(url, path = get_articles_path()){
    file <- googledrive::as_dribble(url)
    path <- path_ext_set(path(path, file$id), path_ext(file$name))
    id <- basename(dirname(path))
    if (file_exists(path)) {
        cli::cli_alert_info("Skipping {basename(path)}, it already exists")
        return(path)
    }
    result <- purrr::safely(googledrive::drive_download)(file, path, verbose = FALSE)
    if (is.null(result$error)) {
        cli::cli_alert_success("{id}: Downloaded {file$id} successfully")
        return(path)
    } else {
        cli::cli_alert_danger("{id}: Failed downloading {file$id} (reason: {result$error$message})")
    }
    return(NA_character_)
}

consume_submissions <- function(subs) {
    for (msgid in names(subs))
        gmailr::modify_message(msgid, remove_labels = "UNREAD")
}

#' @importFrom gmailr mime create_draft
draft_acknowledgements <- function(subs) {
    authorize(c("read_only", "modify", "compose"))
    acknowledge_sub <- function(sub) {
        body <- render_template(sub, "gmail_acknowledge")
        email <- gmailr::mime(From = "rjournal.submission@@gmail.com",
                              To = sub$authors[[1L]]$email,
                              Subject = paste("R Journal submission",
                                  format(sub$id)),
                              body = body)
        gmailr::create_draft(email)
    }
    ans <- lapply(subs, acknowledge_sub)
    names(ans) <- vapply(subs, function(s) format(s$id),
                         FUN.VALUE = character(1L))
    ans
}

#' Send submission acknowledgement drafts
#'
#' @param drafts list of \code{gmail_draft} objects
#' @importFrom gmailr send_draft
#' @export
acknowledge_submissions <- function(drafts) {
    for (draft in drafts) {
        gmailr::send_draft(draft)
    }
    for (id in names(drafts)) {
        update_status(id, "acknowledged")
    }
    invisible(TRUE)
}

#' Send submission acknowledgement drafts
#'
#' @param article article id
#' @export
acknowledge_submission_text <- function(article) {
    article <- as.article(article)

    dest <- file.path(article$path, "correspondence")
    if (!file.exists(dest)) dir.create(dest)

    name <- "acknowledge.txt"
    path <- file.path(dest, name)

    data <- as.data(article)
    data$name <- stringr::str_split(data$name, " ")[[1]][1]
    data$date <- format(Sys.Date() + 30, "%d %b %Y")

    template <- find_template("acknowledge")
    email <- whisker.render(readLines(template), data)

    writeLines(email, path)

    update_status(data$id, "acknowledged")
    invisible(TRUE)
}
