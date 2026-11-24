# gitlab may write backups to ONE bucket and do nothing else in AWS.
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "gitlab" {
  name               = "lab-gitlab-backup"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

data "aws_iam_policy_document" "gitlab_backup" {
  statement {
    actions   = ["s3:PutObject", "s3:GetObject"]
    resources = ["${aws_s3_bucket.backups.arn}/*"]
  }
  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.backups.arn]
  }
}

resource "aws_iam_role_policy" "gitlab_backup" {
  name   = "backup-bucket-only"
  role   = aws_iam_role.gitlab.id
  policy = data.aws_iam_policy_document.gitlab_backup.json
}

resource "aws_iam_instance_profile" "gitlab" {
  name = "lab-gitlab"
  role = aws_iam_role.gitlab.name
}
