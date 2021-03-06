require 'spec_helper'

module ScopeSpec
  describe "Scope" do
    class Blog < ActiveRecord::Base
      has_many :posts
    end

    class Post < ActiveRecord::Base
      belongs_to :blog

      datasource_module do
        query :author_name do
          "posts.author_first_name || ' ' || posts.author_last_name"
        end
      end
    end

    it "works with #first" do
      Post.create! title: "The Post", author_first_name: "John", author_last_name: "Doe", blog_id: 10
      post = Post.with_datasource.datasource_select(:id, :title, :author_name).first

      expect("The Post").to eq(post.title)
      expect("John Doe").to eq(post.author_name)
      expect{post.blog_id}.to raise_error(ActiveModel::MissingAttributeError)
    end

    it "works with #find" do
      post = Post.create! title: "The Post", author_first_name: "John", author_last_name: "Doe", blog_id: 10
      post = Post.with_datasource.datasource_select(:id, :title, :author_name).find(post.id)

      expect("The Post").to eq(post.title)
      expect("John Doe").to eq(post.author_name)
      expect{post.blog_id}.to raise_error(ActiveModel::MissingAttributeError)
    end

    it "works with #each" do
      post = Post.create! title: "The Post", author_first_name: "John", author_last_name: "Doe", blog_id: 10

      Post.with_datasource.datasource_select(:id, :title, :author_name).each do |post|
        expect("The Post").to eq(post.title)
        expect("John Doe").to eq(post.author_name)
        expect{post.blog_id}.to raise_error(ActiveModel::MissingAttributeError)
      end
    end

    it "works with joins" do
      blog = Blog.create! title: "Blog"
      Post.create! title: "The Post", author_first_name: "John", author_last_name: "Doe", blog_id: blog.id
      Post.create! title: "The Other Post", author_first_name: "John", author_last_name: "Doe", blog_id: blog.id
      blog =
        Blog.joins(:posts).where("posts.title = ?", "The Other Post")
        .with_datasource.datasource_select(:id, :title).first

      expect("Blog").to eq(blog.title)
    end

    it "works with includes+references" do
      blog = Blog.create! title: "Blog"
      Post.create! title: "The Post", author_first_name: "John", author_last_name: "Doe", blog_id: blog.id
      Post.create! title: "The Other Post", author_first_name: "John", author_last_name: "Doe", blog_id: blog.id
      blog =
        Blog.includes(:posts).references(:posts).where("posts.title = ?", "The Other Post")
        .with_datasource.datasource_select(:id, :title).first

      expect("Blog").to eq(blog.title)
    end
  end
end
