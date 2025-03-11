#!/bin/bash

# Define SDK, repository, and application directories
INSTALL_DIR="/home/medha/packages/net8"
REPO_PATH="/home/medha/db/mongo"
REPO_URL="https://github.com/mongodb/mongo-csharp-driver.git"
LOG_DIR="/home/medha/db/mongo/logs"
APP_DIR="/home/medha/db/mongo/app"
EMAIL="medhatiwari@ibm.com,Giridhar.Trivedi@ibm.com,Sanjam.Panda@ibm.com"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
LOG_FILE="$LOG_DIR/mongo-cron-$TIMESTAMP.log"

# Set environment variables to use the .NET SDK
export DOTNET_ROOT=$INSTALL_DIR
export PATH=$DOTNET_ROOT:/usr/local/bin:/usr/bin:/bin

# Ensure log directory exists
mkdir -p $LOG_DIR

# Function to send email with results
send_email() {
    local driver_status="$1"
    local app_status="$2"

    {
        echo "Subject: MongoDB C# Driver Build & Test Results"
        echo "To: $EMAIL"
        echo "MIME-Version: 1.0"
        echo "Content-Type: multipart/mixed; boundary=boundary"
        echo
        echo "--boundary"
        echo "Content-Type: text/plain; charset=UTF-8"
        echo "Content-Transfer-Encoding: 7bit"
        echo
        echo "MongoDB C# Driver Status: $driver_status"
        echo ".NET Application Status: $app_status"
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

# Start logging
{
    echo "Using .NET SDK version:"
    dotnet_version=$($INSTALL_DIR/dotnet --version)
    echo "$dotnet_version"

    # Start Sendmail service
    echo "Starting Sendmail service..."
    sudo systemctl start sendmail
    sudo systemctl enable sendmail

    # Clean up any existing repository directory
    if [ -d "$REPO_PATH/mongo-csharp-driver" ]; then
        echo "Removing existing repository at $REPO_PATH/mongo-csharp-driver..."
        rm -rf $REPO_PATH/mongo-csharp-driver
    fi

    # Clone the repository afresh
    echo "Cloning the MongoDB C# driver repository..."
    if git clone $REPO_URL $REPO_PATH/mongo-csharp-driver; then
        cd $REPO_PATH/mongo-csharp-driver

        # Build the project with a timeout
	( timeout 120 $INSTALL_DIR/dotnet build $REPO_PATH/mongo-csharp-driver && DRIVER_STATUS="SUCCESS" ) || {
    	echo "Driver build failed or timed out.";
    	DRIVER_STATUS="FAILED";
	}
	echo "Timeout check completed."

        # Run tests for each test suite
        if [ "$DRIVER_STATUS" == "SUCCESS" ]; then
            echo "Running tests..."
            for test_dir in $REPO_PATH/mongo-csharp-driver/tests/*; do
                if [ -d "$test_dir" ]; then
                    echo "Running tests in $test_dir..."
                    if ! $INSTALL_DIR/dotnet test "$test_dir"; then
                        echo "Tests failed in $test_dir"
                    fi
                fi
            done
        fi
    else
        echo "Failed to clone the repository."
        DRIVER_STATUS="FAILED"
    fi

    # Create and test application connection
    echo "Creating application at $APP_DIR..."
    mkdir -p $APP_DIR
    cd $APP_DIR

    $INSTALL_DIR/dotnet new console -o $APP_DIR --force
    if $INSTALL_DIR/dotnet add package MongoDB.Driver; then
        cat <<EOF > Program.cs
using System;
using MongoDB.Bson;
using MongoDB.Driver;

namespace MongoDBCRUDExample
{
    class Program
    {
        static void Main(string[] args)
        {
            MongoClient dbClient = new MongoClient("mongodb://127.0.0.1:27017/");
            var database = dbClient.GetDatabase("sample_training");
            var collection = database.GetCollection<BsonDocument>("grades");
            Console.WriteLine("Creating record in collection");
            var document = new BsonDocument
            {
                { "student_id", 1 },
                { "scores", new BsonArray
                    {
                    new BsonDocument{ {"type", "quiz"}, {"score", 74.92 } },
                    new BsonDocument{ {"type", "homework"}, {"score", 89.97 } },
                    }
                },
                { "class_id", 480}
            };

            var document2 = new BsonDocument
            {
                { "student_id", 2 },
                { "scores", new BsonArray
                    {
                    new BsonDocument{ {"type", "quiz"}, {"score", 10 } },
                    new BsonDocument{ {"type", "homework"}, {"score", 50 } },
                    }
                },
                { "class_id", 320}
            };

           var Insert = new List<BsonDocument> () {
                document, document2
           };

           collection.InsertMany(Insert);

           var documents = collection.Find(new BsonDocument()).ToList();
           for(int i = 0; i < documents.Count; i++)
               Console.WriteLine(documents[i].ToString());

           Console.WriteLine("\n Updating record at the collection");
           var filter = Builders<BsonDocument>.Filter.Eq("student_id", 1);
           var update = Builders<BsonDocument>.Update.Set("class_id", 483);
           collection.UpdateOne(filter, update);

           documents = collection.Find(new BsonDocument()).ToList();
           for(int i = 0; i < documents.Count; i++)
               Console.WriteLine(documents[i].ToString());

           Console.WriteLine("\n Deleting from the collection");
           var deleteFilter = Builders<BsonDocument>.Filter.Eq("student_id", 1);
           collection.DeleteOne(deleteFilter);

           documents = collection.Find(new BsonDocument()).ToList();
           for(int i = 0; i < documents.Count; i++)
               Console.WriteLine(documents[i].ToString());

        }
    }
}
EOF

        echo "Building application..."
        if $INSTALL_DIR/dotnet build; then
            echo "Running application..."
            if $INSTALL_DIR/dotnet run; then
                APP_STATUS="SUCCESS"
            else
                APP_STATUS="FAILED"
            fi
        else
            APP_STATUS="FAILED"
        fi
    else
        echo "Failed to add MongoDB.Driver package."
        APP_STATUS="FAILED"
    fi

    echo "Build and Test Script Completed on $(date)"
    echo "========================="

} &> "$LOG_FILE"  # Redirect all output to log file

# Send email with results
send_email "$DRIVER_STATUS" "$APP_STATUS"

# Cleanup
if [ -d "$APP_DIR" ]; then
    echo "Cleaning up application directory..."
    rm -rf $APP_DIR
fi

