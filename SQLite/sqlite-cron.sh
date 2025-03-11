#!/bin/bash

# Configurations
REPO_URL="https://github.com/dotnet/efcore.git"
CLONE_DIR="/home/medha/db/sqlite/efcore"
LOG_DIR="/home/medha/db/sqlite/logs"
APP_DIR="/home/medha/db/sqlite/SQLite_Test_App"
EMAIL="medhatiwari@ibm.com,Giridhar.Trivedi@ibm.com,Sanjam.Panda@ibm.com"
DOTNET_ROOT="/home/medha/packages/net8"

# Timestamp for log file
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="$LOG_DIR/sqlite_test_log_$TIMESTAMP.txt"

# Export environment variables for dotnet
export DOTNET_ROOT="$DOTNET_ROOT"
export PATH="$DOTNET_ROOT:$PATH"

# Ensure log directory exists
mkdir -p "$LOG_DIR"

# Initialize statuses
driver_status="failure"
app_status="failure"

# Start logging
echo "Starting SQLite EF Core Test Script..." > "$LOG_FILE"

cleanup() {
    echo "Performing cleanup..." >> "$LOG_FILE"
    [ -d "$CLONE_DIR" ] && rm -rf "$CLONE_DIR" || echo "Failed to delete $CLONE_DIR" >> "$LOG_FILE"
    [ -d "$APP_DIR" ] && rm -rf "$APP_DIR" || echo "Failed to delete $APP_DIR" >> "$LOG_FILE"
}

trap 'cleanup; send_email "$driver_status" "$app_status"' EXIT

# Send email function
send_email() {
    local driver_status="$1"
    local app_status="$2"

    {
        echo "Subject: SQLite EF Core Test Results"
        echo "To: $EMAIL"
        echo "MIME-Version: 1.0"
        echo "Content-Type: multipart/mixed; boundary=boundary"
        echo
        echo "--boundary"
        echo "Content-Type: text/plain; charset=UTF-8"
        echo "Content-Transfer-Encoding: 7bit"
        echo
        echo "EF Core Driver Build: $driver_status"
        echo "Application: $app_status"
        echo
        echo "--boundary"
        echo "Content-Type: text/plain; name=$(basename "$LOG_FILE")"
        echo "Content-Disposition: attachment; filename=$(basename "$LOG_FILE")"
        echo "Content-Transfer-Encoding: base64"
        echo
        base64 "$LOG_FILE"
        echo "--boundary--"
    } | /usr/sbin/sendmail -t
}

{
    # Install SQLite
    echo "Installing SQLite..." >> "$LOG_FILE"
    dnf install -y sqlite sqlite-devel >> "$LOG_FILE" 2>&1 || exit 1

    # Clone EF Core repository
    echo "Cloning EF Core repository..." >> "$LOG_FILE"
    git clone "$REPO_URL" "$CLONE_DIR" >> "$LOG_FILE" 2>&1 || exit 1

    # Checkout to release/8.0 branch
    echo "Checking out release/8.0 branch..." >> "$LOG_FILE"
    git -C "$CLONE_DIR" checkout release/8.0 >> "$LOG_FILE" 2>&1 || exit 1

    # Build EF Core driver
    echo "Building EF Core driver..." >> "$LOG_FILE"
    timeout 120 dotnet build "$CLONE_DIR" >> "$LOG_FILE" 2>&1 && driver_status="success"

    # Create .NET console application
    echo "Creating .NET console application..." >> "$LOG_FILE"
    dotnet new console -o "$APP_DIR" >> "$LOG_FILE" 2>&1 || exit 1

    # Add EF Core packages
    echo "Adding EF Core packages..." >> "$LOG_FILE"
    cd "$APP_DIR"
    dotnet add package Microsoft.EntityFrameworkCore.Sqlite >> "$LOG_FILE" 2>&1 || exit 1
    dotnet add package Microsoft.EntityFrameworkCore.Design >> "$LOG_FILE" 2>&1 || exit 1


    # Add Model.cs
    echo "Writing Model.cs..." >> "$LOG_FILE"
    cat > Model.cs << EOF
using Microsoft.EntityFrameworkCore;
using System;
using System.Collections.Generic;

public class BloggingContext : DbContext {
    public DbSet<Blog> Blogs { get; set; }
    public DbSet<Post> Posts { get; set; }

    public string DbPath { get; }

    public BloggingContext() {
        var folder = Environment.SpecialFolder.LocalApplicationData;
        var path = Environment.GetFolderPath(folder);
        DbPath = System.IO.Path.Join(path, "blogging.db");
    }

    protected override void OnConfiguring(DbContextOptionsBuilder options) => options.UseSqlite($"Data Source={DbPath}");
}

public class Blog {
    public int BlogId { get; set; }
    public string Url { get; set; }
    public List<Post> Posts { get; } = new();
}

public class Post {
    public int PostId { get; set; }
    public string Title { get; set; }
    public string Content { get; set; }
    public int BlogId { get; set; }
    public Blog Blog { get; set; }
}
EOF

    # Add Program.cs
    echo "Writing Program.cs..." >> "$LOG_FILE"
    cat > Program.cs << EOF
using System;
using System.Linq;

public class Program {
  public static void DumpDatabaseSnapshot(BloggingContext db) {
    Console.WriteLine("\nDumping database snapshot...");
    var blogs = db.Blogs.OrderBy(b => b.BlogId).ToList();
    Console.WriteLine("Number of records = {0}", blogs.Count);
    foreach (var b in blogs) {
        Console.WriteLine("BlogId = {0}, Url = {1}", b.BlogId, b.Url);
        foreach (var p in b.Posts) {
            Console.WriteLine("----->PostId = {0}, Title = {1}, Content = {2}", p.PostId, p.Title, p.Content);
        }
    }
    Console.WriteLine("\n");
  }

  public static void Main(string[] args) {
    using var db = new BloggingContext();
    Console.WriteLine($"Database path: {db.DbPath}.");

    Console.WriteLine("Inserting a new blog");
    db.Add(new Blog { Url = "http://blogs.msdn.com/adonet" });
    db.SaveChanges();
    DumpDatabaseSnapshot(db);

    Console.WriteLine("Querying for a blog");
    var blog = db.Blogs.OrderBy(b => b.BlogId).First();
    DumpDatabaseSnapshot(db);

    Console.WriteLine("Updating the blog and adding a post");
    blog.Url = "https://devblogs.microsoft.com/dotnet";
    blog.Posts.Add(new Post { Title = "Hello World", Content = "I wrote an app using EF Core!" });
    db.SaveChanges();
    DumpDatabaseSnapshot(db);

    Console.WriteLine("Delete the blog");
    db.Remove(blog);
    db.SaveChanges();
    DumpDatabaseSnapshot(db);
  }
}
EOF

    echo "Initializing EF Core tool..." >> "$LOG_FILE"
    dotnet new tool-manifest >> "$LOG_FILE" 2>&1
    if ! dotnet tool install --local dotnet-ef >> "$LOG_FILE" 2>&1; then
        echo "Failed to install dotnet-ef tool" >> "$LOG_FILE"
        exit 1
    fi

    # Verify dotnet-ef installation
    if ! dotnet tool run dotnet-ef --version >> "$LOG_FILE" 2>&1; then
        echo "dotnet-ef tool not found in manifest" >> "$LOG_FILE"
        exit 1
    fi

    # Run migrations
    echo "Running migrations..." >> "$LOG_FILE"
    if dotnet tool run dotnet-ef migrations add InitialCreate >> "$LOG_FILE" 2>&1 && dotnet tool run dotnet-ef database update >> "$LOG_FILE" 2>&1; then
        app_status="success"
    else
        echo "Failed to run migrations" >> "$LOG_FILE"
    fi

    # Build and run the application
    echo "Building and running the .NET application..." >> "$LOG_FILE"
    if dotnet build >> "$LOG_FILE" 2>&1 && dotnet run >> "$LOG_FILE" 2>&1; then
        app_status="success"
    else
        app_status="failure"
    fi
    echo "Script completed successfully." >> "$LOG_FILE"
} || {
    echo "An error occurred during script execution." >> "$LOG_FILE"
}
# Ensure cleanup is done
cleanup

